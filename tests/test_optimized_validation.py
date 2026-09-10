import subprocess
import sys
import textwrap
import unittest
from pathlib import Path


class OptimizedValidationSmokeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]

    def _run_optimized(self, code):
        result = subprocess.run(
            [sys.executable, "-O", "-c", textwrap.dedent(code)],
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.returncode,
            0,
            msg=f"Optimized Python smoke test failed.\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        return [line for line in result.stdout.splitlines() if line]

    def test_optimized_python_preserves_validation_errors(self):
        lines = self._run_optimized(
            """
            import types

            import torch

            import prepare
            import train

            tokenizer = types.SimpleNamespace(
                dataset="tinystories",
                get_bos_token_id=lambda: 0,
            )

            try:
                next(prepare.make_dataloader(tokenizer, 1, 8, "bogus", device="cpu"))
            except Exception as exc:
                print(f"prepare:{type(exc).__name__}:{exc}")

            try:
                train.GPT(
                    train.GPTConfig(
                        sequence_len=8,
                        vocab_size=16,
                        n_layer=2,
                        n_head=2,
                        n_kv_head=2,
                        n_embd=32,
                        window_pattern="SX",
                        attention_backend="sdpa",
                        use_activation_checkpointing=False,
                        compute_dtype=torch.float32,
                    )
                )
            except Exception as exc:
                print(f"train-config:{type(exc).__name__}:{exc}")

            model = train.GPT(
                train.GPTConfig(
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
            )
            try:
                model(torch.zeros((1, 9), dtype=torch.long))
            except Exception as exc:
                print(f"train-forward:{type(exc).__name__}:{exc}")
            """
        )

        expected = {
            "prepare": ("ValueError", "Invalid split 'bogus'. Expected one of ('train', 'val', 'test')."),
            "train-config": ("ValueError", "window_pattern"),
            "train-forward": ("ValueError", "Sequence length"),
        }

        seen = {}
        for line in lines:
            name, exc_type, message = line.split(":", 2)
            seen[name] = (exc_type, message)

        self.assertEqual(set(seen), set(expected))
        for name, (exc_type, message_fragment) in expected.items():
            self.assertEqual(seen[name][0], exc_type)
            self.assertIn(message_fragment, seen[name][1])

    def test_optimized_python_rejects_optimizer_parameter_drift(self):
        lines = self._run_optimized(
            """
            import contextlib
            import io
            from unittest import mock

            import torch

            import train

            model = train.GPT(
                train.GPTConfig(
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
            )
            model.init_weights(embed_dtype=torch.float32)

            original_parameters = train.GPT.parameters

            def fake_parameters(self):
                params = list(original_parameters(self))
                params.append(torch.nn.Parameter(torch.zeros(1)))
                return iter(params)

            message = None
            with mock.patch.object(train.GPT, "parameters", fake_parameters):
                with contextlib.redirect_stdout(io.StringIO()):
                    try:
                        model.setup_optimizer(
                            unembedding_lr=0.001,
                            embedding_lr=0.002,
                            scalar_lr=0.003,
                            matrix_lr=0.004,
                            weight_decay=0.0,
                        )
                    except Exception as exc:
                        message = f"optimizer:{type(exc).__name__}:{exc}"

            if message is not None:
                print(message)
            """
        )

        self.assertEqual(len(lines), 1, msg=f"Unexpected optimized output: {lines!r}")
        name, exc_type, message = lines[0].split(":", 2)
        self.assertEqual(name, "optimizer")
        self.assertEqual(exc_type, "OptimizerSetupError")
        self.assertIn("parameter grouping mismatch", message)


if __name__ == "__main__":
    unittest.main()
