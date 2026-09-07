import contextlib
import io
import json
import os
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

import torch

import train


class AutotuneCacheTestCase(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.cache_path = Path(self.temp_dir.name) / "autotune-cache.json"
        self.tokenizer = types.SimpleNamespace(dataset="tinystories")
        self.vocab_size = 32
        self.train_candidates = [(4, False), (2, True)]

    def _make_runtime(
        self,
        *,
        gpu_name="NVIDIA GeForce RTX 4090",
        gpu_cc=(8, 9),
        gpu_total_memory_bytes=24 * 1024 * 1024 * 1024,
        profile_name="ada-24gb-plus",
        train_batch_candidates=(4, 2),
        checkpoint_modes=(False, True),
    ):
        return train.RuntimeConfig(
            device=torch.device("cuda"),
            device_type="cuda",
            amp_dtype=torch.float16,
            use_compile=False,
            use_activation_checkpointing=False,
            attention_backend="sdpa",
            gpu_name=gpu_name,
            gpu_vram_gb=gpu_total_memory_bytes / (1024 ** 3),
            gpu_peak_flops=None,
            gpu_cc=gpu_cc,
            gpu_total_memory_bytes=gpu_total_memory_bytes,
            tf32_enabled=True,
            gpu_profile=train.GpuProfile(
                name=profile_name,
                is_supported_consumer=True,
                is_compatibility_only=False,
                train_batch_candidates=train_batch_candidates,
                checkpoint_modes=checkpoint_modes,
                default_checkpointing=False,
                eval_batch_cap=16,
            ),
        )

    def _write_cache_entry(self, runtime, train_candidates, candidate, *, tok_per_sec=1234.5, peak_memory_bytes=987654321):
        fingerprint = train._build_autotune_cache_fingerprint(
            runtime,
            self.tokenizer.dataset,
            self.vocab_size,
            train_candidates,
        )
        cache_key = train._digest_autotune_cache_fingerprint(fingerprint)
        train._save_autotune_entries(
            self.cache_path,
            {
                cache_key: {
                    "contract": fingerprint,
                    "candidate": {
                        "train_batch_size": candidate[0],
                        "use_activation_checkpointing": candidate[1],
                    },
                    "benchmark": {
                        "tok_per_sec": tok_per_sec,
                        "peak_memory_bytes": peak_memory_bytes,
                    },
                    "updated_unix": 1234567890,
                }
            },
        )
        return fingerprint, cache_key

    def _run_autotune(self, runtime, *, benchmark_side_effect):
        with mock.patch.object(train, "_get_autotune_cache_path", return_value=self.cache_path):
            with mock.patch.object(train, "_benchmark_train_candidate", side_effect=benchmark_side_effect) as benchmark:
                with contextlib.redirect_stdout(io.StringIO()) as buffer:
                    result = train._autotune_train_candidate(
                        runtime,
                        self.tokenizer,
                        self.vocab_size,
                        self.train_candidates,
                    )
        return result, benchmark, buffer.getvalue()

    def test_model_knobs_change_the_cache_key(self):
        runtime = self._make_runtime()
        base_key, base_fingerprint = train._make_autotune_cache_key(
            runtime,
            self.tokenizer.dataset,
            self.vocab_size,
            self.train_candidates,
        )

        with mock.patch.object(train, "DEPTH", train.DEPTH + 2):
            depth_key, _ = train._make_autotune_cache_key(
                runtime,
                self.tokenizer.dataset,
                self.vocab_size,
                self.train_candidates,
            )

        with mock.patch.object(train, "WINDOW_PATTERN", "LSLS"):
            window_key, _ = train._make_autotune_cache_key(
                runtime,
                self.tokenizer.dataset,
                self.vocab_size,
                self.train_candidates,
            )

        self.assertEqual(base_fingerprint["recipe"]["depth"], train.DEPTH)
        self.assertEqual(base_fingerprint["recipe"]["window_pattern"], train.WINDOW_PATTERN)
        self.assertNotEqual(base_key, depth_key)
        self.assertNotEqual(base_key, window_key)

    def test_identical_settings_reuse_the_cached_candidate(self):
        runtime = self._make_runtime()
        candidate = (4, False)
        self._write_cache_entry(runtime, self.train_candidates, candidate)

        result, benchmark, output = self._run_autotune(
            runtime,
            benchmark_side_effect=AssertionError("cache hit should not benchmark"),
        )

        self.assertEqual(result, candidate)
        benchmark.assert_not_called()
        self.assertIn("Using cached autotune candidate", output)

    def test_refresh_forces_a_rebenchmark(self):
        runtime = self._make_runtime()
        self._write_cache_entry(runtime, self.train_candidates, (4, False))

        benchmark_results = [(10.0, 1), (20.0, 2)]
        with mock.patch.dict(os.environ, {"AUTORESEARCH_AUTOTUNE_REFRESH": "1"}, clear=False):
            result, benchmark, output = self._run_autotune(runtime, benchmark_side_effect=benchmark_results)

        self.assertEqual(result, (2, True))
        self.assertEqual(benchmark.call_count, len(self.train_candidates))
        self.assertIn("skipped by AUTORESEARCH_AUTOTUNE_REFRESH=1", output)

    def test_model_recipe_change_invalidates_the_cached_candidate(self):
        runtime = self._make_runtime()
        self._write_cache_entry(runtime, self.train_candidates, (4, False))

        benchmark_results = [(10.0, 1), (20.0, 2)]
        with mock.patch.object(train, "WINDOW_PATTERN", "LSLS"):
            result, benchmark, output = self._run_autotune(runtime, benchmark_side_effect=benchmark_results)

        self.assertEqual(result, (2, True))
        self.assertEqual(benchmark.call_count, len(self.train_candidates))
        self.assertIn("Cached autotune result skipped", output)
        self.assertIn("window_pattern=LSLS", output)

    def test_gpu_identity_fields_prevent_name_fragment_collisions(self):
        runtime_a = self._make_runtime(
            gpu_name="NVIDIA GeForce RTX 4090",
            gpu_cc=(8, 9),
            gpu_total_memory_bytes=24 * 1024 * 1024 * 1024,
        )
        runtime_b = self._make_runtime(
            gpu_name="NVIDIA GeForce RTX 4090",
            gpu_cc=(8, 6),
            gpu_total_memory_bytes=16 * 1024 * 1024 * 1024,
            profile_name="ada-24gb-plus",
            train_batch_candidates=(4, 2),
            checkpoint_modes=(False, True),
        )

        self._write_cache_entry(runtime_a, self.train_candidates, (4, False))
        result, benchmark, output = self._run_autotune(runtime_b, benchmark_side_effect=[(10.0, 1), (20.0, 2)])

        self.assertEqual(result, (2, True))
        self.assertEqual(benchmark.call_count, len(self.train_candidates))
        self.assertIn("Cached autotune result skipped", output)

    def test_older_cache_files_are_ignored_safely(self):
        legacy_payload = {
            "format_version": train.AUTOTUNE_CACHE_FORMAT_VERSION - 1,
            "entries": {
                "legacy-key": {
                    "train_batch_size": 4,
                    "use_activation_checkpointing": False,
                }
            },
        }
        self.cache_path.write_text(json.dumps(legacy_payload), encoding="utf-8")

        with contextlib.redirect_stdout(io.StringIO()) as buffer:
            entries = train._load_autotune_entries(self.cache_path)

        self.assertEqual(entries, {})
        self.assertIn("unsupported", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
