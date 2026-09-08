import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import torch

import train


class CheckpointTestCase(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def _quiet_call(self, func, *args, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return func(*args, **kwargs)

    def _make_runtime(self):
        return train.RuntimeConfig(
            device=torch.device("cpu"),
            device_type="cpu",
            amp_dtype=torch.float32,
            use_compile=False,
            use_activation_checkpointing=False,
            attention_backend="sdpa",
            gpu_name="cpu",
            gpu_vram_gb=0.0,
            gpu_peak_flops=None,
            gpu_cc=(0, 0),
            gpu_total_memory_bytes=0,
            tf32_enabled=False,
            gpu_profile=train.GpuProfile(
                name="cpu-test",
                is_supported_consumer=False,
                is_compatibility_only=True,
                train_batch_candidates=(2,),
                checkpoint_modes=(False,),
                default_checkpointing=False,
                eval_batch_cap=2,
            ),
        )

    def _make_config(self):
        return train.GPTConfig(
            sequence_len=8,
            vocab_size=16,
            n_layer=2,
            n_head=2,
            n_kv_head=2,
            n_embd=32,
            window_pattern="SL",
            attention_backend="sdpa",
            use_activation_checkpointing=False,
            compute_dtype=torch.float32,
        )

    def _make_stateful_model(self):
        config = self._make_config()
        model = train.GPT(config)
        model.init_weights(embed_dtype=torch.float32)
        with mock.patch.object(train, "MUON_COMPUTE_DTYPE", torch.float32):
            optimizer = model.setup_optimizer(
                unembedding_lr=0.001,
                embedding_lr=0.002,
                scalar_lr=0.003,
                matrix_lr=0.004,
                weight_decay=0.0,
            )
            idx = torch.randint(0, config.vocab_size, (2, config.sequence_len))
            targets = torch.randint(0, config.vocab_size, (2, config.sequence_len))
            loss = model(idx, targets)
            loss.backward()
            optimizer.step()
            model.zero_grad(set_to_none=True)
        return config, model, optimizer

    def _make_checkpoint_context(self, *, run_id, runtime, config, device_batch_size, grad_accum_steps, model):
        return {
            "run_id": run_id,
            "status": "cold",
            "resume": {"requested_path": None, "source_path": None},
            "resume_reason": "cold start; no --resume-from path was supplied.",
            "runtime": runtime,
            "config": config,
            "dataset": "tinystories",
            "vocab_size": config.vocab_size,
            "device_batch_size": device_batch_size,
            "grad_accum_steps": grad_accum_steps,
            "target_training_seconds": 10,
            "max_steps": None,
            "smoke_test": True,
            "num_params": sum(p.numel() for p in model.parameters()),
            "num_flops_per_token": model.estimate_flops(),
        }

    def _assert_nested_equal(self, left, right, path="root"):
        if torch.is_tensor(left):
            self.assertTrue(torch.equal(left, right), f"{path} tensor mismatch")
            return
        if isinstance(left, dict):
            self.assertEqual(set(left), set(right), f"{path} keys mismatch")
            for key in left:
                self._assert_nested_equal(left[key], right[key], f"{path}.{key}")
            return
        if isinstance(left, (list, tuple)):
            self.assertEqual(len(left), len(right), f"{path} length mismatch")
            for idx, (l_item, r_item) in enumerate(zip(left, right)):
                self._assert_nested_equal(l_item, r_item, f"{path}[{idx}]")
            return
        self.assertEqual(left, right, f"{path} value mismatch")


class TrainValidationTests(CheckpointTestCase):
    def _make_config(self, **overrides):
        config = train.GPTConfig(
            sequence_len=8,
            vocab_size=16,
            n_layer=2,
            n_head=2,
            n_kv_head=2,
            n_embd=32,
            window_pattern="SL",
            attention_backend="sdpa",
            use_activation_checkpointing=False,
            compute_dtype=torch.float32,
        )
        for key, value in overrides.items():
            setattr(config, key, value)
        return config

    def test_apply_rotary_emb_rejects_rank_mismatch(self):
        x = torch.zeros(2, 3, 4)
        cos = torch.zeros(1, 1, 1, 2)
        sin = torch.zeros(1, 1, 1, 2)

        with self.assertRaisesRegex(ValueError, r"x\.ndim == 4"):
            train.apply_rotary_emb(x, cos, sin)

    def test_causal_self_attention_rejects_invalid_head_layout(self):
        cases = [
            (
                {"n_embd": 30, "n_head": 4, "n_kv_head": 2},
                r"n_embd \(30\) must be divisible by n_head \(4\)\.",
            ),
            (
                {"n_embd": 32, "n_head": 2, "n_kv_head": 3},
                r"n_kv_head \(3\) must be <= n_head \(2\) and divide it evenly\.",
            ),
        ]

        for overrides, expected_message in cases:
            with self.subTest(overrides=overrides):
                config = self._make_config(**overrides)
                with self.assertRaisesRegex(ValueError, expected_message):
                    train.CausalSelfAttention(config, layer_idx=0)

    def test_gpt_rejects_invalid_window_pattern(self):
        config = self._make_config(window_pattern="SX")

        with self.assertRaisesRegex(ValueError, r"window_pattern"):
            train.GPT(config)

    def test_gpt_forward_rejects_sequences_longer_than_rotary_cache(self):
        config = self._make_config(sequence_len=8)
        model = train.GPT(config)
        inputs = torch.zeros((1, config.sequence_len + 1), dtype=torch.long)

        with self.assertRaisesRegex(ValueError, r"Sequence length"):
            model(inputs)


class CheckpointRoundTripTests(CheckpointTestCase):
    def test_checkpoint_round_trip_preserves_model_and_optimizer_state(self):
        runtime = self._make_runtime()
        config, model, optimizer = self._make_stateful_model()
        train_state = {
            "step": 7,
            "epoch": 3,
            "total_training_time": 12.5,
            "smooth_train_loss": 1.25,
            "minibatches_seen": 14,
        }
        run_dir = train._create_run_checkpoint_dir(self.root / "checkpoints", run_id="run-a")
        context = self._make_checkpoint_context(
            run_id=run_dir.name,
            runtime=runtime,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
            model=model,
        )

        checkpoint_path = self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=run_dir,
            context=context,
            model=model,
            optimizer=optimizer,
            train_state=train_state,
            snapshot_reason="initial",
        )
        self.assertEqual(train._resolve_checkpoint_artifact_path(run_dir), checkpoint_path)
        artifact = self._quiet_call(train._load_checkpoint_artifact, checkpoint_path)

        fresh_model = train.GPT(config)
        fresh_model.init_weights(embed_dtype=torch.float32)
        with mock.patch.object(train, "MUON_COMPUTE_DTYPE", torch.float32):
            fresh_optimizer = fresh_model.setup_optimizer(
                unembedding_lr=0.001,
                embedding_lr=0.002,
                scalar_lr=0.003,
                matrix_lr=0.004,
                weight_decay=0.0,
            )

        self._assert_nested_equal(model.state_dict(), artifact["model_state_dict"], "model")
        self._assert_nested_equal(optimizer.state_dict(), artifact["optimizer_state_dict"], "optimizer")
        self._assert_nested_equal(train_state, artifact["train_state"], "train_state")

        fresh_model.load_state_dict(artifact["model_state_dict"])
        fresh_optimizer.load_state_dict(artifact["optimizer_state_dict"])
        train._move_optimizer_state_to_device(fresh_optimizer, torch.device("cpu"))

        self._assert_nested_equal(artifact["model_state_dict"], fresh_model.state_dict(), "fresh_model")
        self._assert_nested_equal(
            artifact["optimizer_state_dict"],
            fresh_optimizer.state_dict(),
            "fresh_optimizer",
        )

        metadata_path = run_dir / train.CHECKPOINT_METADATA_FILE_NAME
        self.assertTrue(metadata_path.exists())
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        self.assertEqual(metadata["snapshot_reason"], "initial")
        self.assertEqual(metadata["run_id"], run_dir.name)

    def test_resumed_checkpoint_keeps_saved_step_and_batch_cursor(self):
        runtime = self._make_runtime()
        config, model, optimizer = self._make_stateful_model()
        train_state = {
            "step": 7,
            "epoch": 3,
            "total_training_time": 12.5,
            "smooth_train_loss": 1.25,
            "minibatches_seen": 14,
        }
        run_dir = train._create_run_checkpoint_dir(self.root / "checkpoints", run_id="run-b")
        context = self._make_checkpoint_context(
            run_id=run_dir.name,
            runtime=runtime,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
            model=model,
        )
        checkpoint_path = self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=run_dir,
            context=context,
            model=model,
            optimizer=optimizer,
            train_state=train_state,
            snapshot_reason="resume",
        )
        artifact = self._quiet_call(train._load_checkpoint_artifact, checkpoint_path)

        self.assertEqual(artifact["train_state"]["step"], 7)
        self.assertEqual(artifact["train_state"]["minibatches_seen"], 14)

        cursor = iter(range(100))
        train._advance_dataloader_batches(cursor, artifact["train_state"]["minibatches_seen"])
        self.assertEqual(next(cursor), 14)

    def test_incompatible_checkpoint_reports_clear_signature_mismatch(self):
        runtime = self._make_runtime()
        config, model, optimizer = self._make_stateful_model()
        run_dir = train._create_run_checkpoint_dir(self.root / "checkpoints", run_id="run-c")
        context = self._make_checkpoint_context(
            run_id=run_dir.name,
            runtime=runtime,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
            model=model,
        )
        checkpoint_path = self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=run_dir,
            context=context,
            model=model,
            optimizer=optimizer,
            train_state={
                "step": 7,
                "epoch": 3,
                "total_training_time": 12.5,
                "smooth_train_loss": 1.25,
                "minibatches_seen": 14,
            },
            snapshot_reason="initial",
        )
        artifact = self._quiet_call(train._load_checkpoint_artifact, checkpoint_path)

        mismatched_config = train.GPTConfig(
            sequence_len=8,
            vocab_size=32,
            n_layer=2,
            n_head=2,
            n_kv_head=2,
            n_embd=32,
            window_pattern="SL",
            attention_backend="sdpa",
            use_activation_checkpointing=False,
            compute_dtype=torch.float32,
        )
        expected = train._build_model_training_signature(
            dataset="tinystories",
            vocab_size=mismatched_config.vocab_size,
            config=mismatched_config,
            device_batch_size=2,
            grad_accum_steps=2,
        )
        actual = artifact["metadata"]["compatibility_signature"]["model_training"]
        issues = train._checkpoint_signature_issues(expected, actual)
        self.assertTrue(issues)
        self.assertTrue(any("vocab_size" in issue for issue in issues))

    def test_missing_resume_path_keeps_cold_start_available(self):
        self.assertIsNone(train._resolve_checkpoint_artifact_path(None))

    def test_concurrent_runs_write_distinct_checkpoint_paths(self):
        runtime = self._make_runtime()
        config, model, optimizer = self._make_stateful_model()
        train_state = {
            "step": 7,
            "epoch": 3,
            "total_training_time": 12.5,
            "smooth_train_loss": 1.25,
            "minibatches_seen": 14,
        }
        root = self.root / "checkpoints"
        run_dir_a = train._create_run_checkpoint_dir(root, run_id="run-a")
        run_dir_b = train._create_run_checkpoint_dir(root, run_id="run-b")
        context_a = self._make_checkpoint_context(
            run_id=run_dir_a.name,
            runtime=runtime,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
            model=model,
        )
        context_b = self._make_checkpoint_context(
            run_id=run_dir_b.name,
            runtime=runtime,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
            model=model,
        )

        path_a = self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=run_dir_a,
            context=context_a,
            model=model,
            optimizer=optimizer,
            train_state=train_state,
            snapshot_reason="initial",
        )
        path_b = self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=run_dir_b,
            context=context_b,
            model=model,
            optimizer=optimizer,
            train_state=train_state,
            snapshot_reason="initial",
        )

        self.assertNotEqual(path_a, path_b)
        self.assertTrue(path_a.exists())
        self.assertTrue(path_b.exists())
        self.assertTrue((run_dir_a / train.CHECKPOINT_METADATA_FILE_NAME).exists())
        self.assertTrue((run_dir_b / train.CHECKPOINT_METADATA_FILE_NAME).exists())


if __name__ == "__main__":
    unittest.main()
