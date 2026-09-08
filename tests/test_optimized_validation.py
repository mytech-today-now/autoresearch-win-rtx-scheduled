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


if __name__ == "__main__":
    unittest.main()
