import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import torch

import prepare
import train


class CheckpointTestCase(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.dataset_sha256 = "a" * 64
        self.split_pattern = prepare.SPLIT_PATTERN
        self.special_tokens = list(prepare.SPECIAL_TOKENS)
        self.mergeable_ranks = {bytes((65 + idx,)): idx for idx in range(12)}
        self.tokenizer_fingerprint = prepare._build_tokenizer_fingerprint(
            self.split_pattern,
            self.special_tokens,
            self.mergeable_ranks,
        )

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
            "dataset_sha256": self.dataset_sha256,
            "tokenizer_fingerprint": self.tokenizer_fingerprint,
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

    def test_setup_optimizer_rejects_parameter_group_drift(self):
        config = self._make_config()
        model = train.GPT(config)
        model.init_weights(embed_dtype=torch.float32)

        original_parameters = train.GPT.parameters

        def fake_parameters(self):
            params = list(original_parameters(self))
            params.append(torch.nn.Parameter(torch.zeros(1)))
            return iter(params)

        with mock.patch.object(train.GPT, "parameters", fake_parameters):
            with self.assertRaisesRegex(train.OptimizerSetupError, r"parameter grouping mismatch"):
                self._quiet_call(
                    model.setup_optimizer,
                    unembedding_lr=0.001,
                    embedding_lr=0.002,
                    scalar_lr=0.003,
                    matrix_lr=0.004,
                    weight_decay=0.0,
                )


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

        expected_signature = train._build_checkpoint_signature(
            dataset=context["dataset"],
            dataset_sha256=context["dataset_sha256"],
            tokenizer_fingerprint=context["tokenizer_fingerprint"],
            vocab_size=context["vocab_size"],
            config=config,
            device_batch_size=context["device_batch_size"],
            grad_accum_steps=context["grad_accum_steps"],
            optimizer=fresh_optimizer,
        )
        restored_train_state = train._restore_checkpoint_state(
            model=fresh_model,
            optimizer=fresh_optimizer,
            resume_artifact=artifact,
            expected_signature=expected_signature,
            device=torch.device("cpu"),
        )

        self._assert_nested_equal(artifact["model_state_dict"], fresh_model.state_dict(), "fresh_model")
        self._assert_nested_equal(
            artifact["optimizer_state_dict"],
            fresh_optimizer.state_dict(),
            "fresh_optimizer",
        )
        self._assert_nested_equal(train_state, restored_train_state, "restored_train_state")

        metadata_path = run_dir / train.CHECKPOINT_METADATA_FILE_NAME
        self.assertTrue(metadata_path.exists())
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        self.assertEqual(metadata["snapshot_reason"], "initial")
        self.assertEqual(metadata["run_id"], run_dir.name)
        self.assertEqual(metadata["dataset_sha256"], context["dataset_sha256"])
        self.assertEqual(metadata["tokenizer_fingerprint"], context["tokenizer_fingerprint"])
        self.assertEqual(
            metadata["compatibility_signature"]["model_training"]["dataset_sha256"],
            context["dataset_sha256"],
        )
        self.assertEqual(
            metadata["compatibility_signature"]["model_training"]["tokenizer_fingerprint"],
            context["tokenizer_fingerprint"],
        )

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
            dataset_sha256=self.dataset_sha256,
            tokenizer_fingerprint=self.tokenizer_fingerprint,
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
        self.assertEqual(
            train._checkpoint_resume_reason(None),
            "cold start; no --resume-from path was supplied.",
        )

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


class CheckpointRecoveryPolicyTests(CheckpointTestCase):
    def test_periodic_save_boundary_keeps_last_checkpoint_until_60_seconds(self):
        class FakeClock:
            def __init__(self, now):
                self.now = now

            def time(self):
                return self.now

            def advance(self, seconds):
                self.now += seconds

        self.assertEqual(train.CHECKPOINT_SAVE_INTERVAL_SECONDS, 60.0)
        runtime = self._make_runtime()
        config, model, optimizer = self._make_stateful_model()
        checkpoint_root = self.root / "checkpoint-root"
        run_dir = train._create_run_checkpoint_dir(checkpoint_root, run_id="interrupted-run")
        context = self._make_checkpoint_context(
            run_id=run_dir.name,
            runtime=runtime,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
            model=model,
        )
        clock = FakeClock(1_000.0)

        self.assertEqual(train._checkpoint_save_reason(None, clock.time()), "initial")
        first_save_time = clock.time()
        self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=run_dir,
            context=context,
            model=model,
            optimizer=optimizer,
            train_state={
                "step": 1,
                "epoch": 1,
                "total_training_time": 1.0,
                "smooth_train_loss": 1.0,
                "minibatches_seen": 2,
            },
            snapshot_reason="initial",
        )

        clock.advance(train.CHECKPOINT_SAVE_INTERVAL_SECONDS - 0.001)
        self.assertIsNone(train._checkpoint_save_reason(first_save_time, clock.time()))
        before_boundary = self._quiet_call(train._load_checkpoint_artifact, run_dir)
        self.assertEqual(before_boundary["train_state"]["step"], 1)

        clock.advance(0.001)
        self.assertEqual(
            train._checkpoint_save_reason(first_save_time, clock.time()),
            "periodic",
        )
        self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=run_dir,
            context=context,
            model=model,
            optimizer=optimizer,
            train_state={
                "step": 2,
                "epoch": 1,
                "total_training_time": 2.0,
                "smooth_train_loss": 0.9,
                "minibatches_seen": 4,
            },
            snapshot_reason="periodic",
        )
        after_boundary = self._quiet_call(train._load_checkpoint_artifact, run_dir)
        self.assertEqual(after_boundary["train_state"]["step"], 2)
        last_save_time = clock.time()
        self.assertIsNone(train._checkpoint_save_reason(last_save_time, clock.time()))

        # Even with a compatible artifact present, omitted --resume-from keeps
        # this recovery contract cold and leaves artifact selection to the operator.
        self.assertIsNone(train._resolve_checkpoint_artifact_path(None))
        self.assertEqual(
            train._checkpoint_resume_reason(None),
            "cold start; no --resume-from path was supplied.",
        )
        next_run = train._create_run_checkpoint_dir(checkpoint_root, run_id="next-cold-run")
        self.assertNotEqual(next_run, run_dir)

    def test_readme_documents_manual_scheduled_recovery_contract(self):
        readme = (Path(__file__).resolve().parents[1] / "README.md").read_text(encoding="utf-8")

        self.assertIn("scheduled runs and `-RunLoop` iterations", readme)
        self.assertIn("starts cold and creates a new run directory", readme)
        self.assertIn("the launcher does not select a checkpoint automatically", readme)
        self.assertIn("pass it explicitly with `--resume-from`", readme)
        self.assertIn("once 60 seconds have elapsed", readme)
        self.assertIn("one interval plus the next training-step duration", readme)


class CheckpointIdentityCompatibilityTests(CheckpointTestCase):
    def _model_training_signature(self, dataset_sha256=None, tokenizer_fingerprint=None):
        config = self._make_config()
        return train._build_model_training_signature(
            dataset="tinystories",
            dataset_sha256=(
                self.dataset_sha256 if dataset_sha256 is None else dataset_sha256
            ),
            tokenizer_fingerprint=(
                self.tokenizer_fingerprint
                if tokenizer_fingerprint is None
                else tokenizer_fingerprint
            ),
            vocab_size=config.vocab_size,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
        )

    def _assert_identity_mismatch_rejected(self, dataset_sha256, tokenizer_fingerprint):
        saved_signature = {"model_training": self._model_training_signature()}
        expected_signature = {
            "model_training": self._model_training_signature(
                dataset_sha256=dataset_sha256,
                tokenizer_fingerprint=tokenizer_fingerprint,
            )
        }
        self.assertEqual(saved_signature["model_training"]["dataset"], "tinystories")
        self.assertEqual(expected_signature["model_training"]["dataset"], "tinystories")
        self.assertEqual(saved_signature["model_training"]["vocab_size"], 16)
        self.assertEqual(expected_signature["model_training"]["vocab_size"], 16)

        model = mock.Mock()
        optimizer = mock.Mock()
        artifact = {
            "metadata": {"compatibility_signature": saved_signature},
            "model_state_dict": {},
            "optimizer_state_dict": {},
            "train_state": {},
            "rng_state": None,
        }
        with self.assertRaises(train.CheckpointCompatibilityError) as error:
            train._restore_checkpoint_state(
                model=model,
                optimizer=optimizer,
                resume_artifact=artifact,
                expected_signature=expected_signature,
                device=torch.device("cpu"),
            )

        self.assertIn("current dataset, tokenizer", str(error.exception))
        model.load_state_dict.assert_not_called()
        optimizer.load_state_dict.assert_not_called()

    def test_dataset_content_hash_mismatch_is_rejected_before_optimizer_restore(self):
        self._assert_identity_mismatch_rejected(
            dataset_sha256="b" * 64,
            tokenizer_fingerprint=self.tokenizer_fingerprint,
        )

    def test_mergeable_rank_mismatch_is_rejected_before_optimizer_restore(self):
        changed_ranks = dict(self.mergeable_ranks)
        changed_ranks[b"A"], changed_ranks[b"B"] = (
            changed_ranks[b"B"],
            changed_ranks[b"A"],
        )
        changed_fingerprint = prepare._build_tokenizer_fingerprint(
            self.split_pattern,
            self.special_tokens,
            changed_ranks,
        )
        self.assertNotEqual(changed_fingerprint, self.tokenizer_fingerprint)
        self._assert_identity_mismatch_rejected(self.dataset_sha256, changed_fingerprint)

    def test_split_pattern_mismatch_is_rejected_before_optimizer_restore(self):
        changed_fingerprint = prepare._build_tokenizer_fingerprint(
            self.split_pattern + "x",
            self.special_tokens,
            self.mergeable_ranks,
        )
        self.assertNotEqual(changed_fingerprint, self.tokenizer_fingerprint)
        self._assert_identity_mismatch_rejected(self.dataset_sha256, changed_fingerprint)

    def test_special_token_map_mismatch_is_rejected_before_optimizer_restore(self):
        changed_fingerprint = prepare._build_tokenizer_fingerprint(
            self.split_pattern,
            list(reversed(self.special_tokens)),
            self.mergeable_ranks,
        )
        self.assertNotEqual(changed_fingerprint, self.tokenizer_fingerprint)
        self._assert_identity_mismatch_rejected(self.dataset_sha256, changed_fingerprint)

    def test_legacy_checkpoint_without_identity_is_rejected_with_cold_start_guidance(self):
        legacy_signature = self._model_training_signature()
        legacy_signature.pop("dataset_sha256")
        legacy_signature.pop("tokenizer_fingerprint")
        model = mock.Mock()
        optimizer = mock.Mock()
        artifact = {
            "metadata": {"compatibility_signature": {"model_training": legacy_signature}},
            "model_state_dict": {},
            "optimizer_state_dict": {},
            "train_state": {},
            "rng_state": None,
        }

        with self.assertRaises(train.CheckpointCompatibilityError) as error:
            train._restore_checkpoint_state(
                model=model,
                optimizer=optimizer,
                resume_artifact=artifact,
                expected_signature={"model_training": self._model_training_signature()},
                device=torch.device("cpu"),
            )

        message = str(error.exception)
        self.assertIn("cannot be safely resumed", message)
        self.assertIn("Start a cold run without --resume-from", message)
        model.load_state_dict.assert_not_called()
        optimizer.load_state_dict.assert_not_called()


class CheckpointRetentionTests(CheckpointTestCase):
    def setUp(self):
        super().setUp()
        self.checkpoint_root = self.root / "artifacts" / "checkpoints"
        self.checkpoint_root.mkdir(parents=True)

    def _make_retention_run(
        self,
        name,
        completed_unix,
        *,
        run_state="successful",
        metadata_overrides=None,
    ):
        run_dir = self.checkpoint_root / name
        run_dir.mkdir()
        metadata = {
            "artifact_kind": "autoresearch-training-checkpoint",
            "format_version": train.CHECKPOINT_FORMAT_VERSION,
            "run_id": name,
            "run_state": run_state,
            "completed_unix": completed_unix,
            "snapshot_reason": "final",
            "compatibility_signature": {
                "model_training": {
                    "dataset": "tinystories",
                    "dataset_sha256": "a" * 64,
                    "tokenizer_fingerprint": "b" * 64,
                    "vocab_size": 16,
                    "device_batch_size": 2,
                    "grad_accum_steps": 2,
                    "total_batch_size": 4,
                    "model": {
                        "sequence_len": 8,
                        "vocab_size": 16,
                        "n_layer": 2,
                        "n_head": 2,
                        "n_kv_head": 2,
                        "n_embd": 32,
                    },
                },
                "optimizer": {
                    "name": "MuonAdamW",
                    "param_group_count": 1,
                    "group_kinds": ["adamw"],
                    "group_param_counts": [1],
                },
            },
            "train_state": {"step": 7},
        }
        if metadata_overrides:
            metadata.update(metadata_overrides)
        checkpoint_path = run_dir / train.CHECKPOINT_FILE_NAME
        checkpoint_path.write_bytes(b"synthetic checkpoint: " + name.encode("utf-8"))
        metadata["checkpoint_size_bytes"] = checkpoint_path.stat().st_size
        metadata_path = run_dir / train.CHECKPOINT_METADATA_FILE_NAME
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        return run_dir

    def test_count_limit_removes_only_eligible_runs_beyond_the_limit(self):
        now = 2_000_000_000
        run_dirs = [
            self._make_retention_run(f"run-{idx}", now - idx * 60)
            for idx in range(6)
        ]

        result = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=3,
            retention_days=30,
            now_unix=now,
        )

        self.assertEqual(len(result["deleted"]), 3)
        self.assertEqual(
            {path.name for path in self.checkpoint_root.iterdir()},
            {run_dirs[idx].name for idx in range(3)},
        )

    def test_age_limit_removes_old_success_but_keeps_newest_success(self):
        now = 2_000_000_000
        newest = self._make_retention_run("run-newest", now)
        recent = self._make_retention_run("run-recent", now - 24 * 60 * 60)
        old = self._make_retention_run("run-old", now - 4 * 24 * 60 * 60)

        result = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=5,
            retention_days=2,
            now_unix=now,
        )

        self.assertEqual(result["deleted"], [str(old)])
        self.assertTrue(newest.exists())
        self.assertTrue(recent.exists())
        self.assertFalse(old.exists())

    def test_active_newest_and_recovery_needed_runs_are_protected(self):
        now = 2_000_000_000
        active = self._make_retention_run(
            "run-active", None, run_state="active", metadata_overrides={"completed_unix": None}
        )
        newest = self._make_retention_run("run-newest", now)
        old = self._make_retention_run("run-old", now - 60)
        pinned = self._make_retention_run("run-pinned", now - 120)
        (pinned / train.CHECKPOINT_RECOVERY_MARKER_FILE_NAME).write_text(
            "manual recovery in progress", encoding="utf-8"
        )
        protected_bytes = {
            run_dir: {
                "metadata": (run_dir / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(),
                "checkpoint": (run_dir / train.CHECKPOINT_FILE_NAME).read_bytes(),
            }
            for run_dir in (active, newest, pinned)
        }

        result = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            retention_days=1,
            now_unix=now,
        )

        self.assertEqual(result["deleted"], [str(old)])
        for run_dir, contents in protected_bytes.items():
            self.assertEqual(
                (run_dir / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(), contents["metadata"]
            )
            self.assertEqual(
                (run_dir / train.CHECKPOINT_FILE_NAME).read_bytes(), contents["checkpoint"]
            )

    def test_malformed_and_incompatible_metadata_remain_untouched(self):
        now = 2_000_000_000
        self._make_retention_run("run-newest", now)
        old = self._make_retention_run("run-old", now - 60)
        malformed = self._make_retention_run("run-malformed", now - 120)
        incompatible = self._make_retention_run(
            "run-incompatible", now - 180, metadata_overrides={"format_version": 999}
        )
        incompatible_signature = self._make_retention_run("run-signature-incompatible", now - 240)
        signature_metadata_path = incompatible_signature / train.CHECKPOINT_METADATA_FILE_NAME
        signature_metadata = json.loads(signature_metadata_path.read_text(encoding="utf-8"))
        signature_metadata["compatibility_signature"]["model_training"]["dataset_sha256"] = "c" * 64
        signature_metadata_path.write_text(json.dumps(signature_metadata), encoding="utf-8")
        size_mismatch = self._make_retention_run("run-checkpoint-size-mismatch", now - 300)
        with (size_mismatch / train.CHECKPOINT_FILE_NAME).open("ab") as checkpoint_stream:
            checkpoint_stream.write(b"unexpected trailing data")
        malformed_metadata = malformed / train.CHECKPOINT_METADATA_FILE_NAME
        malformed_metadata.write_text("{invalid json", encoding="utf-8")
        preserved = {
            path: {
                "metadata": (path / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(),
                "checkpoint": (path / train.CHECKPOINT_FILE_NAME).read_bytes(),
            }
            for path in (malformed, incompatible, incompatible_signature, size_mismatch)
        }

        result = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            retention_days=1,
            now_unix=now,
        )

        self.assertEqual(result["deleted"], [str(old)])
        for path, contents in preserved.items():
            self.assertEqual(
                (path / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(), contents["metadata"]
            )
            self.assertEqual(
                (path / train.CHECKPOINT_FILE_NAME).read_bytes(), contents["checkpoint"]
            )

    def test_newest_recovery_pinned_run_remains_the_compatibility_anchor(self):
        now = 2_000_000_000
        pinned_newest = self._make_retention_run("run-pinned-newest", now)
        metadata_path = pinned_newest / train.CHECKPOINT_METADATA_FILE_NAME
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        metadata["compatibility_signature"]["model_training"]["dataset_sha256"] = "c" * 64
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        (pinned_newest / train.CHECKPOINT_RECOVERY_MARKER_FILE_NAME).write_text(
            "manual recovery in progress", encoding="utf-8"
        )
        recent_incompatible = self._make_retention_run("run-recent-incompatible", now - 60)
        older_incompatible = self._make_retention_run("run-older-incompatible", now - 120)
        older_checkpoint = (older_incompatible / train.CHECKPOINT_FILE_NAME).read_bytes()

        result = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            retention_days=30,
            now_unix=now,
        )

        self.assertEqual(result["deleted"], [])
        self.assertTrue(pinned_newest.exists())
        self.assertTrue(recent_incompatible.exists())
        self.assertEqual(
            (older_incompatible / train.CHECKPOINT_FILE_NAME).read_bytes(), older_checkpoint
        )

    def test_path_escape_is_rejected_and_outside_artifacts_are_preserved(self):
        outside_run = self.root / "outside" / "run-escape"
        outside_run.mkdir(parents=True)
        outside_checkpoint = outside_run / train.CHECKPOINT_FILE_NAME
        outside_checkpoint.write_bytes(b"outside user data")

        self.assertFalse(
            train._is_safe_checkpoint_run_dir(self.checkpoint_root, outside_run)
        )
        self.assertFalse(
            train._is_safe_checkpoint_run_dir(
                self.checkpoint_root,
                self.checkpoint_root / ".." / ".." / "outside" / "run-escape",
            )
        )
        self._make_retention_run("run-newest", 2_000_000_000)

        self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            now_unix=2_000_000_000,
        )

        self.assertEqual(outside_checkpoint.read_bytes(), b"outside user data")

    def test_cleanup_refuses_checkpoint_root_beneath_reparse_point(self):
        linked_parent = self.root / "linked-parent"
        linked_parent.mkdir()
        checkpoint_root = linked_parent / "checkpoints"

        def is_reparse_point(path):
            return Path(path) == linked_parent

        with mock.patch.object(train, "_is_reparse_point", side_effect=is_reparse_point):
            with self.assertRaisesRegex(ValueError, "linked root or parent"):
                train.cleanup_checkpoint_runs(checkpoint_root)

    def test_dry_run_selects_paths_without_deleting_or_changing_files(self):
        now = 2_000_000_000
        self._make_retention_run("run-newest", now)
        old = self._make_retention_run("run-old", now - 60)
        before = {
            path.name: {
                "metadata": (path / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(),
                "checkpoint": (path / train.CHECKPOINT_FILE_NAME).read_bytes(),
            }
            for path in (self.checkpoint_root / "run-newest", old)
        }

        result = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            retention_days=30,
            dry_run=True,
            now_unix=now,
        )

        self.assertEqual(result["selected"], [str(old)])
        self.assertEqual(result["deleted"], [])
        for name, contents in before.items():
            run_dir = self.checkpoint_root / name
            self.assertEqual(
                (run_dir / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(), contents["metadata"]
            )
            self.assertEqual(
                (run_dir / train.CHECKPOINT_FILE_NAME).read_bytes(), contents["checkpoint"]
            )

    def test_cleanup_cli_dry_run_does_not_delete_files(self):
        now = 2_000_000_000
        self._make_retention_run("run-newest", now)
        old = self._make_retention_run("run-old", now - 60)
        old_checkpoint = (old / train.CHECKPOINT_FILE_NAME).read_bytes()
        old_metadata = (old / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes()

        with mock.patch.object(
            sys,
            "argv",
            [
                "train.py",
                "--cleanup-checkpoints",
                "--dry-run",
                "--checkpoint-root",
                str(self.checkpoint_root),
                "--checkpoint-retention-count",
                "1",
            ],
        ):
            exit_code = self._quiet_call(train.main)

        self.assertEqual(exit_code, 0)
        self.assertEqual((old / train.CHECKPOINT_FILE_NAME).read_bytes(), old_checkpoint)
        self.assertEqual((old / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(), old_metadata)

    def test_partial_delete_failure_is_reported_and_other_targets_are_processed(self):
        now = 2_000_000_000
        newest = self._make_retention_run("run-newest", now)
        failing = self._make_retention_run("run-failing", now - 60)
        deletable = self._make_retention_run("run-deletable", now - 120)
        real_rmtree = train.shutil.rmtree

        def fail_one_target(path):
            if Path(path) == failing:
                raise OSError("simulated sharing violation")
            return real_rmtree(path)

        with mock.patch.object(train.shutil, "rmtree", side_effect=fail_one_target):
            result = self._quiet_call(
                train.cleanup_checkpoint_runs,
                self.checkpoint_root,
                retention_count=1,
                retention_days=30,
                now_unix=now,
            )

        self.assertTrue(newest.exists())
        self.assertTrue(failing.exists())
        self.assertFalse(deletable.exists())
        self.assertEqual(result["deleted"], [str(deletable)])
        self.assertEqual(len(result["failed"]), 1)
        self.assertEqual(result["failed"][0]["path"], str(failing))

    def test_cleanup_is_idempotent(self):
        now = 2_000_000_000
        self._make_retention_run("run-newest", now)
        old = self._make_retention_run("run-old", now - 60)

        first = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            retention_days=30,
            now_unix=now,
        )
        second = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            retention_days=30,
            now_unix=now,
        )

        self.assertEqual(first["deleted"], [str(old)])
        self.assertEqual(second["selected"], [])
        self.assertEqual(second["deleted"], [])

    def test_retention_keeps_resumable_checkpoint_and_optimizer_state(self):
        now = 2_000_000_000
        runtime = self._make_runtime()
        config, model, optimizer = self._make_stateful_model()
        train_state = {
            "step": 7,
            "epoch": 3,
            "total_training_time": 12.5,
            "smooth_train_loss": 1.25,
            "minibatches_seen": 14,
        }
        run_dir = train._create_run_checkpoint_dir(
            self.checkpoint_root, run_id="resume-source"
        )
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
            snapshot_reason="final",
        )
        self._quiet_call(
            train._mark_checkpoint_run_successful, run_dir, completed_unix=now
        )
        checkpoint_bytes = checkpoint_path.read_bytes()
        metadata_bytes = (run_dir / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes()
        old_run_dir = train._create_run_checkpoint_dir(
            self.checkpoint_root, run_id="old-compatible"
        )
        old_context = self._make_checkpoint_context(
            run_id=old_run_dir.name,
            runtime=runtime,
            config=config,
            device_batch_size=2,
            grad_accum_steps=2,
            model=model,
        )
        self._quiet_call(
            train._save_run_checkpoint,
            checkpoint_dir=old_run_dir,
            context=old_context,
            model=model,
            optimizer=optimizer,
            train_state=train_state,
            snapshot_reason="final",
        )
        self._quiet_call(
            train._mark_checkpoint_run_successful,
            old_run_dir,
            completed_unix=now - 31 * 24 * 60 * 60,
        )

        result = self._quiet_call(
            train.cleanup_checkpoint_runs,
            self.checkpoint_root,
            retention_count=1,
            retention_days=30,
            now_unix=now,
        )

        self.assertEqual(result["deleted"], [str(old_run_dir)])
        self.assertEqual(checkpoint_path.read_bytes(), checkpoint_bytes)
        self.assertEqual(
            (run_dir / train.CHECKPOINT_METADATA_FILE_NAME).read_bytes(), metadata_bytes
        )
        artifact = self._quiet_call(train._load_checkpoint_artifact, checkpoint_path)

        fresh_config, fresh_model, fresh_optimizer = self._make_stateful_model()
        expected_signature = train._build_checkpoint_signature(
            dataset="tinystories",
            dataset_sha256=self.dataset_sha256,
            tokenizer_fingerprint=self.tokenizer_fingerprint,
            vocab_size=fresh_config.vocab_size,
            config=fresh_config,
            device_batch_size=2,
            grad_accum_steps=2,
            optimizer=fresh_optimizer,
        )
        restored_state = self._quiet_call(
            train._restore_checkpoint_state,
            model=fresh_model,
            optimizer=fresh_optimizer,
            resume_artifact=artifact,
            expected_signature=expected_signature,
            device=torch.device("cpu"),
        )

        self.assertEqual(restored_state, train_state)
        self._assert_nested_equal(
            artifact["optimizer_state_dict"], fresh_optimizer.state_dict(), "optimizer_state"
        )
        cursor = iter(range(100))
        train._advance_dataloader_batches(cursor, restored_state["minibatches_seen"])
        self.assertEqual(next(cursor), 14)


if __name__ == "__main__":
    unittest.main()
