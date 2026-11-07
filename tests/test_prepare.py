import contextlib
import hashlib
import io
import json
import os
import tempfile
import threading
import types
import unittest
from unittest import mock

import requests
import torch

import prepare


class FakeResponse:
    def __init__(self, *, body=b"", status_code=200):
        self.body = body
        self.status_code = status_code

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(
                f"HTTP {self.status_code}",
                response=self,
            )

    def iter_content(self, chunk_size=1024 * 1024):
        for offset in range(0, len(self.body), chunk_size):
            yield self.body[offset:offset + chunk_size]


class PrepareTestCase(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)

        self.cache_dir = self.temp_dir.name
        self.datasets_dir = os.path.join(self.cache_dir, "datasets")
        self.active_dataset_path = os.path.join(self.cache_dir, "active_dataset.txt")

        self._patchers = [
            mock.patch.object(prepare, "CACHE_DIR", self.cache_dir),
            mock.patch.object(prepare, "DATASETS_DIR", self.datasets_dir),
            mock.patch.object(prepare, "ACTIVE_DATASET_PATH", self.active_dataset_path),
        ]
        for patcher in self._patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def _quiet_call(self, func, *args, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            return func(*args, **kwargs)

    def _write_tokenizer_cache(
        self,
        *,
        dataset="tinystories",
        version=1,
        vocab_size=5,
        mergeable_ranks=None,
    ):
        payload = {
            "cache_kind": prepare.TOKENIZER_CACHE_KIND,
            "format_version": version,
            "dataset": dataset,
            "dataset_sha256": prepare._dataset_sha256(dataset),
            "vocab_size": vocab_size,
            "pattern": prepare.SPLIT_PATTERN,
            "special_tokens": list(prepare.SPECIAL_TOKENS),
            "mergeable_ranks": mergeable_ranks or {"00": 0},
        }
        path = os.path.join(
            self.cache_dir,
            "datasets",
            dataset,
            "tokenizer",
            f"tokenizer.v{version}.json",
        )
        prepare._write_json_cache(path, payload)
        return path

    def _write_token_bytes_cache(
        self,
        *,
        dataset="tinystories",
        version=1,
        vocab_size=5,
        token_bytes=None,
    ):
        token_bytes_list = token_bytes.tolist() if hasattr(token_bytes, "tolist") else token_bytes
        payload = {
            "cache_kind": prepare.TOKEN_BYTES_CACHE_KIND,
            "format_version": version,
            "dataset": dataset,
            "dataset_sha256": prepare._dataset_sha256(dataset),
            "vocab_size": vocab_size,
            "token_bytes": token_bytes_list or list(range(vocab_size)),
        }
        path = os.path.join(
            self.cache_dir,
            "datasets",
            dataset,
            "tokenizer",
            f"token_bytes.v{version}.json",
        )
        prepare._write_json_cache(path, payload)
        return path


class PrepareMainTests(PrepareTestCase):
    def test_main_prepares_clean_cache(self):
        call_log = []

        def record(name):
            def _inner(dataset_name):
                call_log.append((name, dataset_name))
            return _inner

        with mock.patch.object(prepare, "download_data", side_effect=record("download")):
            with mock.patch.object(prepare, "train_tokenizer", side_effect=record("train")):
                with mock.patch.object(prepare, "_set_active_dataset", side_effect=record("activate")):
                    exit_code = self._quiet_call(prepare.main, ["--dataset", "tinystories"])

        self.assertEqual(exit_code, 0)
        self.assertEqual(
            call_log,
            [
                ("download", "tinystories"),
                ("train", "tinystories"),
                ("activate", "tinystories"),
            ],
        )

    def test_main_aborts_before_activation_when_download_fails(self):
        with mock.patch.object(
            prepare,
            "download_data",
            side_effect=prepare.DatasetIntegrityError(
                "Integrity error: TinyStories parquet failed checksum verification."
            ),
        ):
            with mock.patch.object(prepare, "train_tokenizer") as mock_train:
                with mock.patch.object(prepare, "_set_active_dataset") as mock_activate:
                    exit_code = self._quiet_call(prepare.main, ["--dataset", "tinystories"])

        self.assertEqual(exit_code, 1)
        mock_train.assert_not_called()
        mock_activate.assert_not_called()


class PrepareTokenizerCacheTests(PrepareTestCase):
    def test_tokenizer_cache_paths_are_dataset_scoped(self):
        tokenizer_path = prepare._tokenizer_cache_path("tinystories")
        token_bytes_path = prepare._token_bytes_cache_path("tinystories")
        expected_prefix = os.path.join(self.cache_dir, "datasets", "tinystories", "tokenizer")

        self.assertTrue(tokenizer_path.startswith(expected_prefix))
        self.assertTrue(token_bytes_path.startswith(expected_prefix))
        self.assertTrue(
            tokenizer_path.endswith(f"tokenizer.v{prepare.TOKENIZER_CACHE_VERSION}.json")
        )
        self.assertTrue(
            token_bytes_path.endswith(f"token_bytes.v{prepare.TOKEN_BYTES_CACHE_VERSION}.json")
        )

    def test_tokenizer_cache_rejects_malformed_file_before_deserialization(self):
        path = prepare._tokenizer_cache_path("tinystories")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(b"\x80\x04bad-pickle")

        with mock.patch.object(prepare, "train_tokenizer") as mock_train:
            with self.assertRaises(prepare.TokenizerCacheError):
                self._quiet_call(prepare.Tokenizer.from_directory, dataset="tinystories")

        mock_train.assert_not_called()

    def test_tokenizer_cache_round_trips_valid_data(self):
        self._write_tokenizer_cache(vocab_size=5)

        with mock.patch.object(prepare, "VOCAB_SIZE", 5):
            tokenizer = self._quiet_call(prepare.Tokenizer.from_directory, dataset="tinystories")

        self.assertEqual(tokenizer.dataset, "tinystories")
        self.assertEqual(tokenizer.get_vocab_size(), 5)
        self.assertEqual(tokenizer.get_bos_token_id(), 1)

    def test_tokenizer_cache_persists_fingerprint_and_verified_dataset_hash(self):
        path = prepare._tokenizer_cache_path("tinystories")
        mergeable_ranks = {b"A": 0}
        dataset_sha256 = prepare._dataset_sha256("tinystories")

        with mock.patch.object(prepare, "VOCAB_SIZE", 5):
            prepare._save_tokenizer_cache(
                path,
                "tinystories",
                prepare.SPLIT_PATTERN,
                mergeable_ranks,
            )
            with open(path, "r", encoding="utf-8") as cache_file:
                payload = json.load(cache_file)

            expected_fingerprint = prepare._build_tokenizer_fingerprint(
                prepare.SPLIT_PATTERN,
                prepare.SPECIAL_TOKENS,
                mergeable_ranks,
            )
            with mock.patch.object(
                prepare,
                "_verify_tinystories_parquet",
                return_value=dataset_sha256,
            ) as verify_dataset:
                tokenizer = self._quiet_call(
                    prepare.Tokenizer.from_directory,
                    dataset="tinystories",
                    verify_dataset=True,
                )

        self.assertEqual(payload["tokenizer_fingerprint"], expected_fingerprint)
        self.assertEqual(tokenizer.dataset_sha256, dataset_sha256)
        self.assertEqual(tokenizer.tokenizer_fingerprint, expected_fingerprint)
        verify_dataset.assert_called_once_with(
            prepare._resolve_tiny_parquet_for_read("tinystories"),
            "tinystories",
        )

    def test_tokenizer_loads_successfully_after_format_version_bump(self):
        self._write_tokenizer_cache(vocab_size=5, version=1)

        def regenerate(dataset_name):
            self._write_tokenizer_cache(dataset=dataset_name, version=2, vocab_size=5)

        with mock.patch.object(prepare, "VOCAB_SIZE", 5):
            with mock.patch.object(prepare, "TOKENIZER_CACHE_VERSION", 2):
                with mock.patch.object(prepare, "train_tokenizer", side_effect=regenerate) as mock_train:
                    tokenizer = self._quiet_call(
                        prepare.Tokenizer.from_directory,
                        dataset="tinystories",
                    )

        mock_train.assert_called_once_with("tinystories")
        self.assertEqual(tokenizer.dataset, "tinystories")
        self.assertEqual(tokenizer.get_vocab_size(), 5)
        self.assertEqual(tokenizer.get_bos_token_id(), 1)

    def test_token_bytes_cache_rejects_malformed_file_before_deserialization(self):
        path = prepare._token_bytes_cache_path("tinystories")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(b"\x80\x04bad-pickle")

        with mock.patch.object(prepare, "train_tokenizer") as mock_train:
            with self.assertRaises(prepare.TokenizerCacheError):
                self._quiet_call(prepare.get_token_bytes, dataset="tinystories")

        mock_train.assert_not_called()

    def test_token_bytes_cache_round_trips_same_tensor(self):
        token_bytes = torch.tensor([0, 1, 2, 3, 4], dtype=torch.int32)
        self._write_token_bytes_cache(token_bytes=token_bytes, vocab_size=5)

        with mock.patch.object(prepare, "VOCAB_SIZE", 5):
            loaded = self._quiet_call(prepare.get_token_bytes, dataset="tinystories")

        self.assertTrue(torch.equal(loaded.cpu(), token_bytes))

    def test_missing_token_bytes_cache_triggers_regeneration(self):
        token_bytes = torch.tensor([4, 3, 2, 1, 0], dtype=torch.int32)

        def regenerate(dataset_name):
            self._write_token_bytes_cache(
                dataset=dataset_name,
                token_bytes=token_bytes,
                vocab_size=5,
            )

        with mock.patch.object(prepare, "VOCAB_SIZE", 5):
            with mock.patch.object(prepare, "train_tokenizer", side_effect=regenerate) as mock_train:
                loaded = self._quiet_call(prepare.get_token_bytes, dataset="tinystories")

        mock_train.assert_called_once_with("tinystories")
        self.assertTrue(torch.equal(loaded.cpu(), token_bytes))


class PrepareValidationTests(PrepareTestCase):
    def test_train_tokenizer_raises_on_roundtrip_mismatch(self):
        fake_tokenizer = mock.Mock()
        fake_tokenizer.train_from_iterator.return_value = None
        fake_tokenizer.get_pattern.return_value = prepare.SPLIT_PATTERN
        fake_tokenizer.get_mergeable_ranks.return_value = [(b"a", 0)]

        fake_encoding = mock.Mock()
        fake_encoding.n_vocab = len(prepare.SPECIAL_TOKENS) + 1
        fake_encoding.encode_ordinary.return_value = [0]
        fake_encoding.decode.return_value = "not-a-roundtrip"

        with mock.patch.object(prepare, "list_parquet_files", return_value=["dummy.parquet"]):
            with mock.patch.object(prepare.rustbpe, "Tokenizer", return_value=fake_tokenizer):
                with mock.patch.object(prepare.tiktoken, "Encoding", return_value=fake_encoding):
                    with self.assertRaisesRegex(RuntimeError, r"Tokenizer roundtrip failed: .* -> .*"):
                        self._quiet_call(prepare.train_tokenizer, "tinystories")

    def test_document_batches_rejects_invalid_split(self):
        with self.assertRaisesRegex(ValueError, r"Invalid split 'bogus'"):
            next(prepare._document_batches("bogus", dataset="tinystories"))

    def test_make_dataloader_rejects_test_split_for_non_tinystories_dataset(self):
        tokenizer = types.SimpleNamespace(
            dataset="other",
            get_bos_token_id=lambda: 0,
        )

        with mock.patch.object(prepare, "_resolve_dataset_name", return_value="other"):
            with mock.patch.object(
                prepare,
                "_document_batches",
                side_effect=AssertionError("_document_batches should not be reached"),
            ) as mock_batches:
                loader = prepare.make_dataloader(tokenizer, 1, 8, "test", device="cpu")
                with self.assertRaisesRegex(ValueError, "Test split exists only for TinyStories."):
                    next(loader)

        mock_batches.assert_not_called()


class PrepareDownloadTests(PrepareTestCase):
    def _download_temp_files(self, current_path):
        data_dir = os.path.dirname(current_path)
        return [
            os.path.join(data_dir, name)
            for name in os.listdir(data_dir)
            if name.endswith(".tmp")
        ]

    def test_download_accepts_valid_file_with_expected_hash(self):
        payload = b"valid tiny stories payload"
        digest = hashlib.sha256(payload).hexdigest()
        current_path = prepare._tiny_parquet_path("tinystories")

        with mock.patch.dict(prepare.DATASET_CONFIGS["tinystories"], {"sha256": digest}):
            with mock.patch.object(
                prepare.requests,
                "get",
                return_value=FakeResponse(body=payload, status_code=200),
            ) as mock_get:
                self._quiet_call(prepare._download_tinystories_file, "tinystories")

        mock_get.assert_called_once()
        self.assertTrue(os.path.exists(current_path))
        with open(current_path, "rb") as f:
            self.assertEqual(f.read(), payload)
        self.assertEqual(self._download_temp_files(current_path), [])

    def test_download_retries_transient_503_before_succeeding(self):
        payload = b"retryable payload"
        digest = hashlib.sha256(payload).hexdigest()
        current_path = prepare._tiny_parquet_path("tinystories")
        responses = [
            FakeResponse(status_code=503),
            FakeResponse(body=payload, status_code=200),
        ]

        def fake_get(*args, **kwargs):
            return responses.pop(0)

        with mock.patch.dict(prepare.DATASET_CONFIGS["tinystories"], {"sha256": digest}):
            with mock.patch.object(prepare.requests, "get", side_effect=fake_get) as mock_get:
                with mock.patch.object(prepare.time, "sleep", return_value=None) as mock_sleep:
                    self._quiet_call(prepare._download_tinystories_file, "tinystories")

        self.assertEqual(mock_get.call_count, 2)
        mock_sleep.assert_called_once()
        self.assertTrue(os.path.exists(current_path))
        with open(current_path, "rb") as f:
            self.assertEqual(f.read(), payload)
        self.assertEqual(self._download_temp_files(current_path), [])

    def test_download_gives_up_after_bounded_transient_failures(self):
        current_path = prepare._tiny_parquet_path("tinystories")
        responses = [FakeResponse(status_code=503) for _ in range(prepare.DATA_DOWNLOAD_MAX_ATTEMPTS)]

        def fake_get(*args, **kwargs):
            return responses.pop(0)

        with mock.patch.object(prepare.requests, "get", side_effect=fake_get) as mock_get:
            with mock.patch.object(prepare.time, "sleep", return_value=None) as mock_sleep:
                with self.assertRaises(prepare.DatasetTransportError) as cm:
                    self._quiet_call(prepare._download_tinystories_file, "tinystories")

        self.assertIn("Transport error", str(cm.exception))
        self.assertEqual(mock_get.call_count, prepare.DATA_DOWNLOAD_MAX_ATTEMPTS)
        self.assertEqual(mock_sleep.call_count, prepare.DATA_DOWNLOAD_MAX_ATTEMPTS - 1)
        self.assertFalse(os.path.exists(current_path))
        self.assertEqual(self._download_temp_files(current_path), [])

    def test_download_rejects_corrupt_download(self):
        expected_payload = b"expected payload"
        bad_payload = b"truncated payload"
        current_path = prepare._tiny_parquet_path("tinystories")

        with mock.patch.dict(
            prepare.DATASET_CONFIGS["tinystories"],
            {"sha256": hashlib.sha256(expected_payload).hexdigest()},
        ):
            with mock.patch.object(
                prepare.requests,
                "get",
                return_value=FakeResponse(body=bad_payload, status_code=200),
            ):
                with self.assertRaises(prepare.DatasetIntegrityError) as cm:
                    self._quiet_call(prepare._download_tinystories_file, "tinystories")

        self.assertIn("Integrity error", str(cm.exception))
        self.assertFalse(os.path.exists(current_path))
        self.assertEqual(self._download_temp_files(current_path), [])

    def test_download_reuses_existing_valid_file_without_redownloading(self):
        payload = b"already verified"
        digest = hashlib.sha256(payload).hexdigest()
        current_path = prepare._tiny_parquet_path("tinystories")
        os.makedirs(os.path.dirname(current_path), exist_ok=True)
        with open(current_path, "wb") as f:
            f.write(payload)

        with mock.patch.dict(prepare.DATASET_CONFIGS["tinystories"], {"sha256": digest}):
            with mock.patch.object(prepare.requests, "get") as mock_get:
                self._quiet_call(prepare._download_tinystories_file, "tinystories")

        mock_get.assert_not_called()
        with open(current_path, "rb") as f:
            self.assertEqual(f.read(), payload)
        self.assertEqual(self._download_temp_files(current_path), [])

    def test_download_reports_file_placement_error(self):
        payload = b"placement payload"
        digest = hashlib.sha256(payload).hexdigest()
        current_path = prepare._tiny_parquet_path("tinystories")

        with mock.patch.dict(prepare.DATASET_CONFIGS["tinystories"], {"sha256": digest}):
            with mock.patch.object(
                prepare.requests,
                "get",
                return_value=FakeResponse(body=payload, status_code=200),
            ):
                with mock.patch.object(prepare.os, "replace", side_effect=OSError("disk full")):
                    with self.assertRaises(prepare.DatasetPlacementError) as cm:
                        self._quiet_call(prepare._download_tinystories_file, "tinystories")

        self.assertIn("File placement error", str(cm.exception))
        self.assertFalse(os.path.exists(current_path))
        self.assertEqual(self._download_temp_files(current_path), [])

    def test_concurrent_downloads_use_isolated_temporary_files(self):
        payload = b"concurrent TinyStories payload"
        digest = hashlib.sha256(payload).hexdigest()
        current_path = prepare._tiny_parquet_path("tinystories")
        partial_prefix = payload[:12]
        a_partial_written = threading.Event()
        b_partial_written = threading.Event()
        allow_a_failure = threading.Event()
        allow_b_finish = threading.Event()
        a_retry_started = threading.Event()
        temp_paths = {}
        request_counts = {"download-a": 0, "download-b": 0}
        state_lock = threading.Lock()
        errors = []

        class InterruptedFirstResponse(FakeResponse):
            def iter_content(self, chunk_size=1024 * 1024):
                yield b"caller-a-partial"
                a_partial_written.set()
                if not allow_a_failure.wait(timeout=10):
                    raise RuntimeError("timed out waiting to interrupt download A")
                raise requests.ConnectionError("synthetic interrupted stream")

        class PausedSecondResponse(FakeResponse):
            def iter_content(self, chunk_size=1024 * 1024):
                yield partial_prefix
                b_partial_written.set()
                if not allow_b_finish.wait(timeout=10):
                    raise RuntimeError("timed out waiting to finish download B")
                yield payload[len(partial_prefix):]

        def fake_get(*args, **kwargs):
            thread_name = threading.current_thread().name
            with state_lock:
                request_counts[thread_name] += 1
                attempt = request_counts[thread_name]

            if thread_name == "download-a":
                if attempt == 1:
                    return InterruptedFirstResponse()
                if attempt == 2:
                    a_retry_started.set()
                    raise requests.ConnectionError("synthetic retry interruption")
                return FakeResponse(body=payload, status_code=200)
            if thread_name == "download-b" and attempt == 1:
                return PausedSecondResponse()
            raise AssertionError(f"unexpected download request: {thread_name}, attempt {attempt}")

        original_download = prepare._download_url_with_retries

        def record_and_download(url, temp_path, description):
            with state_lock:
                temp_paths[threading.current_thread().name] = temp_path
            return original_download(url, temp_path, description)

        def run_download():
            try:
                prepare._download_tinystories_file("tinystories")
            except Exception as exc:
                with state_lock:
                    errors.append(exc)

        threads = [
            threading.Thread(target=run_download, name="download-a"),
            threading.Thread(target=run_download, name="download-b"),
        ]
        b_temp_survived_a_retry = False

        with mock.patch.dict(prepare.DATASET_CONFIGS["tinystories"], {"sha256": digest}):
            with mock.patch.object(prepare.requests, "get", side_effect=fake_get):
                with mock.patch.object(prepare.time, "sleep", return_value=None):
                    with mock.patch.object(
                        prepare,
                        "_download_url_with_retries",
                        side_effect=record_and_download,
                    ):
                        with contextlib.redirect_stdout(io.StringIO()):
                            for thread in threads:
                                thread.start()
                            try:
                                self.assertTrue(a_partial_written.wait(timeout=10))
                                self.assertTrue(b_partial_written.wait(timeout=10))
                                with state_lock:
                                    paths = dict(temp_paths)
                                self.assertEqual(set(paths), {"download-a", "download-b"})
                                self.assertNotEqual(paths["download-a"], paths["download-b"])
                                self.assertEqual(
                                    os.path.dirname(paths["download-a"]),
                                    os.path.dirname(current_path),
                                )
                                self.assertEqual(
                                    os.path.dirname(paths["download-b"]),
                                    os.path.dirname(current_path),
                                )
                                self.assertTrue(os.path.exists(paths["download-a"]))
                                self.assertTrue(os.path.exists(paths["download-b"]))

                                allow_a_failure.set()
                                self.assertTrue(
                                    a_retry_started.wait(timeout=10),
                                    f"request_counts={request_counts}, errors={errors}",
                                )
                                b_temp_survived_a_retry = os.path.exists(paths["download-b"])
                            finally:
                                allow_a_failure.set()
                                allow_b_finish.set()
                                for thread in threads:
                                    thread.join(timeout=10)

        self.assertTrue(all(not thread.is_alive() for thread in threads))
        self.assertEqual(errors, [])
        self.assertTrue(b_temp_survived_a_retry)
        self.assertEqual(request_counts, {"download-a": 3, "download-b": 1})
        with mock.patch.dict(prepare.DATASET_CONFIGS["tinystories"], {"sha256": digest}):
            self.assertEqual(
                prepare._verify_tinystories_parquet(current_path, "tinystories"),
                digest,
            )
        self.assertEqual(self._download_temp_files(current_path), [])


if __name__ == "__main__":
    unittest.main()
