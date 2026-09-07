import contextlib
import hashlib
import io
import os
import tempfile
import unittest
from unittest import mock

import requests

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


class PrepareDownloadTests(PrepareTestCase):
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
        self.assertFalse(os.path.exists(current_path + ".tmp"))

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
        self.assertFalse(os.path.exists(current_path + ".tmp"))

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
        self.assertFalse(os.path.exists(current_path + ".tmp"))

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
        self.assertFalse(os.path.exists(current_path + ".tmp"))


if __name__ == "__main__":
    unittest.main()
