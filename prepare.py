"""
One-time data preparation for autoresearch experiments.
Downloads data and trains a BPE tokenizer.

Usage:
    python prepare.py

Data and tokenizer are stored in the cache directory (overridable with
AUTORESEARCH_CACHE_DIR). The active dataset can be pinned with
AUTORESEARCH_DATASET or by running this script with --dataset.
"""

import argparse
import hashlib
import json
import math
import os
import shutil
import time

import pyarrow.parquet as pq
import requests
import rustbpe
import tiktoken
import torch

# ---------------------------------------------------------------------------
# Constants (fixed, do not modify)
# ---------------------------------------------------------------------------

MAX_SEQ_LEN = 2048          # context length
TIME_BUDGET = 300           # training time budget in seconds (5 minutes)
EVAL_TOKENS = 40 * 524288   # number of tokens for validation eval
VOCAB_SIZE = 8192

# BPE split pattern (GPT-4 style, with \p{N}{1,2} instead of {1,3})
SPLIT_PATTERN = r"""'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,2}| ?[^\s\p{L}\p{N}]++[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+"""

SPECIAL_TOKENS = [f"<|reserved_{i}|>" for i in range(4)]
BOS_TOKEN = "<|reserved_0|>"

# ---------------------------------------------------------------------------
# Dataset + cache configuration
# ---------------------------------------------------------------------------

DEFAULT_DATASET = "tinystories"
DATASET_CHOICES = ("tinystories",)


def _default_cache_dir():
    env_cache = os.environ.get("AUTORESEARCH_CACHE_DIR")
    if env_cache:
        return os.path.expanduser(env_cache)

    legacy_cache = os.path.join(os.path.expanduser("~"), ".cache", "autoresearch")
    if os.name != "nt":
        return legacy_cache

    if os.path.exists(legacy_cache):
        return legacy_cache

    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        return os.path.join(local_app_data, "autoresearch")
    return legacy_cache


CACHE_DIR = _default_cache_dir()
DATASETS_DIR = os.path.join(CACHE_DIR, "datasets")
ACTIVE_DATASET_PATH = os.path.join(CACHE_DIR, "active_dataset.txt")

DATA_DOWNLOAD_TIMEOUT_SECONDS = 60
DATA_DOWNLOAD_MAX_ATTEMPTS = 4
DATA_DOWNLOAD_INITIAL_BACKOFF_SECONDS = 1.0
DATA_DOWNLOAD_MAX_BACKOFF_SECONDS = 8.0
DATA_DOWNLOAD_CHUNK_SIZE = 1024 * 1024
TRANSIENT_HTTP_STATUSES = {408, 429, 500, 502, 503, 504}

DATASET_CONFIGS = {
    "tinystories": {
        "filename": "tinystories_gpt4_clean.parquet",
        "sha256": "8bacd849e57784e06ebaaab3ef7b01077ca2d9d27ce7d95f2fbe465f1483548b",
        "url": "https://huggingface.co/datasets/karpathy/tinystories-gpt4-clean/resolve/main/tinystories_gpt4_clean.parquet",
        "splits": {
            "test": (0, 10_000),
            "val": (10_000, 20_000),
            "train": (20_000, None),
        },
    },
}


class DatasetTransportError(RuntimeError):
    """Raised when the dataset download cannot complete over the network."""


class DatasetIntegrityError(RuntimeError):
    """Raised when a downloaded dataset file does not match the pinned checksum."""


class DatasetPlacementError(RuntimeError):
    """Raised when a verified dataset file cannot be moved into place."""


class TokenizerCacheError(RuntimeError):
    """Raised when a tokenizer cache file is missing, mismatched, or corrupt."""


TOKENIZER_CACHE_VERSION = 1
TOKEN_BYTES_CACHE_VERSION = 1
TOKENIZER_CACHE_KIND = "tokenizer"
TOKEN_BYTES_CACHE_KIND = "token_bytes"


def _normalize_dataset_name(dataset_name):
    if dataset_name is None:
        return None
    value = dataset_name.strip().lower()
    if value not in DATASET_CHOICES:
        raise ValueError(f"Unknown dataset '{dataset_name}'. Expected one of {DATASET_CHOICES}.")
    return value


def _load_active_dataset_from_file():
    if not os.path.exists(ACTIVE_DATASET_PATH):
        return None
    with open(ACTIVE_DATASET_PATH, "r", encoding="utf-8") as f:
        value = f.read().strip().lower()
    if value in DATASET_CHOICES:
        return value
    return None


def _resolve_dataset_name(dataset_name=None):
    normalized = _normalize_dataset_name(dataset_name)
    if normalized is not None:
        return normalized

    env_value = os.environ.get("AUTORESEARCH_DATASET")
    try:
        env_dataset = _normalize_dataset_name(env_value)
    except ValueError:
        print(
            f"Warning: ignoring unsupported AUTORESEARCH_DATASET={env_value!r}; "
            f"using '{DEFAULT_DATASET}'."
        )
        env_dataset = None
    if env_dataset is not None:
        return env_dataset

    file_dataset = _load_active_dataset_from_file()
    if file_dataset is not None:
        return file_dataset

    return DEFAULT_DATASET


def _set_active_dataset(dataset_name):
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(ACTIVE_DATASET_PATH, "w", encoding="utf-8") as f:
        f.write(dataset_name + "\n")


def _dataset_root(dataset_name=None):
    dataset = _resolve_dataset_name(dataset_name)
    return os.path.join(DATASETS_DIR, dataset)


def _data_dir(dataset_name=None):
    return os.path.join(_dataset_root(dataset_name), "data")


def _tokenizer_dir(dataset_name=None):
    return os.path.join(_dataset_root(dataset_name), "tokenizer")


def _tokenizer_cache_path(dataset_name=None):
    return os.path.join(
        _tokenizer_dir(dataset_name),
        f"tokenizer.v{TOKENIZER_CACHE_VERSION}.json",
    )


def _token_bytes_cache_path(dataset_name=None):
    return os.path.join(
        _tokenizer_dir(dataset_name),
        f"token_bytes.v{TOKEN_BYTES_CACHE_VERSION}.json",
    )


def _write_json_cache(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp_path = path + ".tmp"
    try:
        with open(temp_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
        os.replace(temp_path, path)
    except (OSError, TypeError) as exc:
        _remove_path(temp_path)
        raise TokenizerCacheError(
            f"Tokenizer cache write error at {path}: {exc}"
        ) from exc


def _load_json_cache(path, cache_kind, dataset_name, expected_version):
    dataset = _resolve_dataset_name(dataset_name)
    if not os.path.exists(path):
        raise FileNotFoundError(path)

    try:
        with open(path, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} is not valid JSON: {exc}"
        ) from exc

    if not isinstance(payload, dict):
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} must contain a JSON object."
        )

    if payload.get("cache_kind") != cache_kind:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has unexpected kind {payload.get('cache_kind')!r}."
        )

    if payload.get("format_version") != expected_version:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has format version {payload.get('format_version')!r}, "
            f"expected {expected_version}."
        )

    if payload.get("dataset") != dataset:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} is for dataset {payload.get('dataset')!r}, "
            f"expected {dataset!r}."
        )

    expected_sha256 = _dataset_sha256(dataset)
    if payload.get("dataset_sha256") != expected_sha256:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has dataset sha256 {payload.get('dataset_sha256')!r}, "
            f"expected {expected_sha256!r}."
        )

    return payload


def _save_tokenizer_cache(path, dataset, pattern, mergeable_ranks):
    payload = {
        "cache_kind": TOKENIZER_CACHE_KIND,
        "format_version": TOKENIZER_CACHE_VERSION,
        "dataset": dataset,
        "dataset_sha256": _dataset_sha256(dataset),
        "vocab_size": VOCAB_SIZE,
        "pattern": pattern,
        "special_tokens": list(SPECIAL_TOKENS),
        "mergeable_ranks": {token.hex(): rank for token, rank in mergeable_ranks.items()},
    }
    _write_json_cache(path, payload)


def _load_tokenizer_cache(path, dataset_name=None):
    payload = _load_json_cache(
        path,
        TOKENIZER_CACHE_KIND,
        dataset_name,
        TOKENIZER_CACHE_VERSION,
    )

    if payload.get("pattern") != SPLIT_PATTERN:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has an unexpected split pattern."
        )

    if payload.get("special_tokens") != list(SPECIAL_TOKENS):
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has unexpected special tokens."
        )

    if payload.get("vocab_size") != VOCAB_SIZE:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has vocab size {payload.get('vocab_size')!r}, "
            f"expected {VOCAB_SIZE}."
        )

    mergeable_ranks_payload = payload.get("mergeable_ranks")
    if not isinstance(mergeable_ranks_payload, dict):
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} must store mergeable ranks as an object."
        )

    mergeable_ranks = {}
    for token_hex, rank in mergeable_ranks_payload.items():
        if not isinstance(token_hex, str) or type(rank) is not int:
            raise TokenizerCacheError(
                f"Tokenizer cache at {path} has an invalid mergeable-rank entry."
            )
        try:
            token_bytes = bytes.fromhex(token_hex)
        except ValueError as exc:
            raise TokenizerCacheError(
                f"Tokenizer cache at {path} has an invalid token encoding."
            ) from exc
        mergeable_ranks[token_bytes] = rank

    expected_mergeable_ranks = VOCAB_SIZE - len(SPECIAL_TOKENS)
    if len(mergeable_ranks) != expected_mergeable_ranks:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has {len(mergeable_ranks)} mergeable ranks, "
            f"expected {expected_mergeable_ranks}."
        )

    expected_ranks = list(range(expected_mergeable_ranks))
    if sorted(mergeable_ranks.values()) != expected_ranks:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has non-contiguous mergeable-rank ids."
        )

    token_offset = len(mergeable_ranks)
    special_tokens = {name: token_offset + i for i, name in enumerate(SPECIAL_TOKENS)}
    enc = tiktoken.Encoding(
        name="rustbpe",
        pat_str=payload["pattern"],
        mergeable_ranks=mergeable_ranks,
        special_tokens=special_tokens,
    )
    if enc.n_vocab != VOCAB_SIZE:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} rebuilt to vocab size {enc.n_vocab}, "
            f"expected {VOCAB_SIZE}."
        )
    return enc


def _save_token_bytes_cache(path, dataset, token_bytes):
    token_bytes_list = (
        token_bytes.tolist() if hasattr(token_bytes, "tolist") else list(token_bytes)
    )
    payload = {
        "cache_kind": TOKEN_BYTES_CACHE_KIND,
        "format_version": TOKEN_BYTES_CACHE_VERSION,
        "dataset": dataset,
        "dataset_sha256": _dataset_sha256(dataset),
        "vocab_size": VOCAB_SIZE,
        "token_bytes": token_bytes_list,
    }
    _write_json_cache(path, payload)


def _load_token_bytes_cache(path, dataset_name=None, device="cpu"):
    payload = _load_json_cache(
        path,
        TOKEN_BYTES_CACHE_KIND,
        dataset_name,
        TOKEN_BYTES_CACHE_VERSION,
    )

    if payload.get("vocab_size") != VOCAB_SIZE:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has vocab size {payload.get('vocab_size')!r}, "
            f"expected {VOCAB_SIZE}."
        )

    token_bytes = payload.get("token_bytes")
    if not isinstance(token_bytes, list):
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} must store token bytes as a JSON array."
        )

    if len(token_bytes) != VOCAB_SIZE:
        raise TokenizerCacheError(
            f"Tokenizer cache at {path} has {len(token_bytes)} token bytes, "
            f"expected {VOCAB_SIZE}."
        )

    for value in token_bytes:
        if type(value) is not int or value < 0:
            raise TokenizerCacheError(
                f"Tokenizer cache at {path} has an invalid token-byte entry."
            )

    return torch.tensor(token_bytes, dtype=torch.int32, device=device)


def _tiny_parquet_path(dataset_name=None):
    dataset = _resolve_dataset_name(dataset_name)
    config = DATASET_CONFIGS[dataset]
    return os.path.join(_data_dir(dataset), config["filename"])


def _tiny_legacy_parquet_paths(dataset_name=None):
    dataset = _resolve_dataset_name(dataset_name)
    data_dir = _data_dir(dataset)
    legacy_flat_data_dir = os.path.join(CACHE_DIR, "data")
    return (
        os.path.join(data_dir, "tinystories_gpt4-clean.parquet"),
        os.path.join(legacy_flat_data_dir, "tinystories_gpt4_clean.parquet"),
        os.path.join(legacy_flat_data_dir, "tinystories_gpt4-clean.parquet"),
    )


def _dataset_sha256(dataset_name):
    config = DATASET_CONFIGS[dataset_name]
    return config["sha256"]


def _sha256_file(path, chunk_size=DATA_DOWNLOAD_CHUNK_SIZE):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _remove_path(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _verify_tinystories_parquet(path, dataset_name):
    expected_sha256 = _dataset_sha256(dataset_name)
    if not os.path.exists(path):
        raise DatasetIntegrityError(
            f"Integrity error: TinyStories parquet is missing at {path}."
        )

    actual_sha256 = _sha256_file(path)
    if actual_sha256 != expected_sha256:
        raise DatasetIntegrityError(
            "Integrity error: TinyStories parquet at "
            f"{path} has sha256 {actual_sha256}, expected {expected_sha256}."
        )

    return actual_sha256


def _download_url_with_retries(url, temp_path, description):
    backoff_seconds = DATA_DOWNLOAD_INITIAL_BACKOFF_SECONDS
    for attempt in range(1, DATA_DOWNLOAD_MAX_ATTEMPTS + 1):
        _remove_path(temp_path)
        try:
            with requests.get(
                url,
                stream=True,
                timeout=DATA_DOWNLOAD_TIMEOUT_SECONDS,
            ) as response:
                try:
                    response.raise_for_status()
                except requests.HTTPError as exc:
                    status_code = getattr(response, "status_code", None)
                    if (
                        status_code in TRANSIENT_HTTP_STATUSES
                        and attempt < DATA_DOWNLOAD_MAX_ATTEMPTS
                    ):
                        print(
                            f"Data: transient HTTP {status_code} while downloading {description} "
                            f"(attempt {attempt}/{DATA_DOWNLOAD_MAX_ATTEMPTS}); retrying in "
                            f"{backoff_seconds:.1f}s..."
                        )
                        time.sleep(backoff_seconds)
                        backoff_seconds = min(
                            backoff_seconds * 2,
                            DATA_DOWNLOAD_MAX_BACKOFF_SECONDS,
                        )
                        continue
                    raise DatasetTransportError(
                        f"Transport error downloading {description}: HTTP {status_code} from {url}."
                    ) from exc

                try:
                    with open(temp_path, "wb") as f:
                        for chunk in response.iter_content(
                            chunk_size=DATA_DOWNLOAD_CHUNK_SIZE,
                        ):
                            if chunk:
                                f.write(chunk)
                except OSError as exc:
                    _remove_path(temp_path)
                    raise DatasetPlacementError(
                        f"File placement error while writing {description} to {temp_path}: {exc}"
                    ) from exc
            return
        except requests.RequestException as exc:
            _remove_path(temp_path)
            if attempt < DATA_DOWNLOAD_MAX_ATTEMPTS:
                print(
                    f"Data: transport error while downloading {description} "
                    f"(attempt {attempt}/{DATA_DOWNLOAD_MAX_ATTEMPTS}): {exc}. "
                    f"Retrying in {backoff_seconds:.1f}s..."
                )
                time.sleep(backoff_seconds)
                backoff_seconds = min(
                    backoff_seconds * 2,
                    DATA_DOWNLOAD_MAX_BACKOFF_SECONDS,
                )
                continue
            raise DatasetTransportError(
                f"Transport error downloading {description} after {DATA_DOWNLOAD_MAX_ATTEMPTS} attempts: {exc}"
            ) from exc


def _promote_verified_download(temp_path, filepath, description):
    try:
        os.replace(temp_path, filepath)
    except OSError as exc:
        _remove_path(temp_path)
        raise DatasetPlacementError(
            f"File placement error moving verified {description} into {filepath}: {exc}"
        ) from exc


def _resolve_tiny_parquet_for_read(dataset_name=None):
    dataset = _resolve_dataset_name(dataset_name)
    data_dir = _data_dir(dataset)
    current_path = _tiny_parquet_path(dataset)
    if os.path.exists(current_path):
        return current_path

    for legacy_path in _tiny_legacy_parquet_paths(dataset):
        if not os.path.exists(legacy_path):
            continue
        os.makedirs(data_dir, exist_ok=True)
        try:
            os.replace(legacy_path, current_path)
            print(f"Data: migrated legacy TinyStories parquet to {current_path}")
            return current_path
        except OSError:
            try:
                shutil.copy2(legacy_path, current_path)
                print(f"Data: copied legacy TinyStories parquet to {current_path}")
                return current_path
            except OSError:
                return legacy_path
    return current_path


# ---------------------------------------------------------------------------
# Data download (TinyStories only)
# ---------------------------------------------------------------------------


def _download_tinystories_file(dataset_name):
    config = DATASET_CONFIGS[dataset_name]
    data_dir = _data_dir(dataset_name)
    os.makedirs(data_dir, exist_ok=True)

    filename = config["filename"]
    filepath = os.path.join(data_dir, filename)
    temp_path = filepath + ".tmp"

    if os.path.exists(filepath):
        try:
            _verify_tinystories_parquet(filepath, dataset_name)
        except DatasetIntegrityError:
            print(
                f"Data: existing {filename} at {filepath} failed integrity check; redownloading."
            )
            _remove_path(filepath)
        else:
            print(f"Data: {filename} already downloaded at {filepath}")
            return

    for legacy_path in _tiny_legacy_parquet_paths(dataset_name):
        if not os.path.exists(legacy_path):
            continue
        try:
            _verify_tinystories_parquet(legacy_path, dataset_name)
        except DatasetIntegrityError:
            print(
                f"Data: ignoring stale legacy TinyStories parquet at {legacy_path} after integrity failure."
            )
            _remove_path(legacy_path)
            continue
        try:
            os.replace(legacy_path, filepath)
            print(f"Data: migrated legacy TinyStories parquet to {filepath}")
            return
        except OSError:
            try:
                shutil.copy2(legacy_path, filepath)
                print(f"Data: copied legacy TinyStories parquet to {filepath}")
                return
            except OSError as exc:
                raise DatasetPlacementError(
                    f"File placement error copying legacy TinyStories parquet from {legacy_path} to {filepath}: {exc}"
                ) from exc

    url = config["url"]
    print(f"Data: downloading {filename}...")
    _download_url_with_retries(url, temp_path, filename)
    try:
        _verify_tinystories_parquet(temp_path, dataset_name)
    except DatasetIntegrityError:
        _remove_path(temp_path)
        raise
    _promote_verified_download(temp_path, filepath, filename)
    print(f"Data: downloaded {filename} to {filepath}")


def download_data(dataset_name):
    dataset = _resolve_dataset_name(dataset_name)
    _download_tinystories_file(dataset)


# ---------------------------------------------------------------------------
# Tokenizer training
# ---------------------------------------------------------------------------

def list_parquet_files(dataset_name=None):
    dataset = _resolve_dataset_name(dataset_name)
    data_dir = _data_dir(dataset)
    files = []
    if os.path.exists(data_dir):
        files = sorted(
            name for name in os.listdir(data_dir)
            if name.endswith(".parquet") and not name.endswith(".tmp")
        )
    if files:
        return [os.path.join(data_dir, name) for name in files]
    if dataset == "tinystories":
        tiny_path = _resolve_tiny_parquet_for_read(dataset)
        if os.path.exists(tiny_path):
            return [tiny_path]
    return []


def _iter_tinystories_texts(split, dataset_name=None):
    dataset = _resolve_dataset_name(dataset_name)
    config = DATASET_CONFIGS[dataset]
    start_idx, end_idx = config["splits"][split]
    tiny_path = _resolve_tiny_parquet_for_read(dataset)

    if not os.path.exists(tiny_path):
        raise FileNotFoundError(
            f"TinyStories parquet not found at {tiny_path}. Run prepare.py first."
        )

    current_idx = 0
    parquet_file = pq.ParquetFile(tiny_path)
    for row_group_idx in range(parquet_file.num_row_groups):
        row_group = parquet_file.read_row_group(row_group_idx, columns=["text"])
        texts = row_group.column("text").to_pylist()
        for text in texts:
            if current_idx < start_idx:
                current_idx += 1
                continue
            if end_idx is not None and current_idx >= end_idx:
                return
            yield text
            current_idx += 1


def text_iterator(dataset_name=None, max_chars=1_000_000_000, doc_cap=10_000):
    dataset = _resolve_dataset_name(dataset_name)
    chars = 0

    text_iter = _iter_tinystories_texts("train", dataset_name=dataset)
    for text in text_iter:
        doc = text[:doc_cap] if len(text) > doc_cap else text
        chars += len(doc)
        yield doc
        if chars >= max_chars:
            return


def train_tokenizer(dataset_name=None):
    dataset = _resolve_dataset_name(dataset_name)
    tokenizer_dir = _tokenizer_dir(dataset)
    tokenizer_cache_path = _tokenizer_cache_path(dataset)
    token_bytes_path = _token_bytes_cache_path(dataset)

    if os.path.exists(tokenizer_cache_path) and os.path.exists(token_bytes_path):
        _load_tokenizer_cache(tokenizer_cache_path, dataset_name=dataset)
        _load_token_bytes_cache(token_bytes_path, dataset_name=dataset)
        print(f"Tokenizer: already trained at {tokenizer_dir}")
        return

    os.makedirs(tokenizer_dir, exist_ok=True)

    parquet_files = list_parquet_files(dataset)
    if len(parquet_files) < 1:
        print("Tokenizer: TinyStories parquet is missing. Run prepare.py first.")
        raise RuntimeError("TinyStories parquet is missing.")

    print(f"Tokenizer: training BPE tokenizer ({dataset})...")
    t0 = time.time()
    tokenizer = rustbpe.Tokenizer()
    vocab_size_no_special = VOCAB_SIZE - len(SPECIAL_TOKENS)
    tokenizer.train_from_iterator(
        text_iterator(dataset_name=dataset),
        vocab_size_no_special,
        pattern=SPLIT_PATTERN,
    )

    pattern = tokenizer.get_pattern()
    mergeable_ranks = {bytes(k): v for k, v in tokenizer.get_mergeable_ranks()}
    token_offset = len(mergeable_ranks)
    special_tokens = {name: token_offset + i for i, name in enumerate(SPECIAL_TOKENS)}
    enc = tiktoken.Encoding(
        name="rustbpe",
        pat_str=pattern,
        mergeable_ranks=mergeable_ranks,
        special_tokens=special_tokens,
    )

    _save_tokenizer_cache(tokenizer_cache_path, dataset, pattern, mergeable_ranks)

    t1 = time.time()
    print(f"Tokenizer: trained in {t1 - t0:.1f}s, saved to {tokenizer_cache_path}")

    print("Tokenizer: building token_bytes lookup...")
    special_set = set(SPECIAL_TOKENS)
    token_bytes_list = []
    for token_id in range(enc.n_vocab):
        token_str = enc.decode([token_id])
        if token_str in special_set:
            token_bytes_list.append(0)
        else:
            token_bytes_list.append(len(token_str.encode("utf-8")))
    _save_token_bytes_cache(token_bytes_path, dataset, token_bytes_list)
    print(f"Tokenizer: saved token_bytes to {token_bytes_path}")

    with open(os.path.join(tokenizer_dir, "dataset.txt"), "w", encoding="utf-8") as f:
        f.write(dataset + "\n")

    test = "Hello world! Numbers: 123. Unicode: 你好"
    encoded = enc.encode_ordinary(test)
    decoded = enc.decode(encoded)
    assert decoded == test, f"Tokenizer roundtrip failed: {test!r} -> {decoded!r}"
    print(f"Tokenizer: sanity check passed (vocab_size={enc.n_vocab})")


# ---------------------------------------------------------------------------
# Runtime utilities (imported by train.py)
# ---------------------------------------------------------------------------

class Tokenizer:
    """Minimal tokenizer wrapper. Training is handled above."""

    def __init__(self, enc, dataset):
        self.enc = enc
        self.dataset = _resolve_dataset_name(dataset)
        self.bos_token_id = enc.encode_single_token(BOS_TOKEN)

    @classmethod
    def from_directory(cls, tokenizer_dir=None, dataset=None):
        dataset_name = _resolve_dataset_name(dataset)
        if tokenizer_dir is None:
            tokenizer_cache_path = _tokenizer_cache_path(dataset_name)
        else:
            tokenizer_cache_path = os.path.join(
                tokenizer_dir,
                f"tokenizer.v{TOKENIZER_CACHE_VERSION}.json",
            )
        if not os.path.exists(tokenizer_cache_path):
            if tokenizer_dir is None:
                train_tokenizer(dataset_name)
            if not os.path.exists(tokenizer_cache_path):
                raise FileNotFoundError(
                    f"Tokenizer cache not found at {tokenizer_cache_path}. Run prepare.py first."
                )
        enc = _load_tokenizer_cache(tokenizer_cache_path, dataset_name=dataset_name)
        return cls(enc, dataset=dataset_name)

    def get_vocab_size(self):
        return self.enc.n_vocab

    def get_bos_token_id(self):
        return self.bos_token_id

    def encode(self, text, prepend=None, num_threads=8):
        if prepend is not None:
            prepend_id = prepend if isinstance(prepend, int) else self.enc.encode_single_token(prepend)
        if isinstance(text, str):
            ids = self.enc.encode_ordinary(text)
            if prepend is not None:
                ids.insert(0, prepend_id)
        elif isinstance(text, list):
            ids = self.enc.encode_ordinary_batch(text, num_threads=num_threads)
            if prepend is not None:
                for row in ids:
                    row.insert(0, prepend_id)
        else:
            raise ValueError(f"Invalid input type: {type(text)}")
        return ids

    def decode(self, ids):
        return self.enc.decode(ids)


def get_token_bytes(device="cpu", dataset=None):
    dataset_name = _resolve_dataset_name(dataset)
    path = _token_bytes_cache_path(dataset_name)
    if not os.path.exists(path):
        train_tokenizer(dataset_name)
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"Token-byte cache not found at {path}. Run prepare.py first."
        )
    return _load_token_bytes_cache(path, dataset_name=dataset_name, device=device)


def _document_batches(split, dataset=None, tokenizer_batch_size=128):
    dataset_name = _resolve_dataset_name(dataset)
    assert split in ("train", "val", "test")

    epoch = 1
    while True:
        batch = []
        for text in _iter_tinystories_texts(split, dataset_name=dataset_name):
            batch.append(text)
            if len(batch) >= tokenizer_batch_size:
                yield batch, epoch
                batch = []
        if batch:
            yield batch, epoch
        epoch += 1


def make_dataloader(tokenizer, B, T, split, device="cuda", dataset=None, buffer_size=1000):
    """
    BOS-aligned dataloader with best-fit packing.
    Every row starts with BOS. Documents packed using best-fit to minimize cropping.
    When no document fits remaining space, crops shortest doc to fill exactly.
    100% utilization (no padding).
    """
    dataset_name = _resolve_dataset_name(dataset or getattr(tokenizer, "dataset", None))
    if split == "test":
        assert dataset_name == "tinystories", "Test split exists only for TinyStories."
    assert split in ("train", "val", "test")

    row_capacity = T + 1
    batches = _document_batches(split, dataset=dataset_name)
    bos_token = tokenizer.get_bos_token_id()
    doc_buffer = []
    epoch = 1
    resolved_device = torch.device(device)
    use_cuda = resolved_device.type == "cuda"

    def refill_buffer():
        nonlocal epoch
        doc_batch, epoch = next(batches)
        token_lists = tokenizer.encode(doc_batch, prepend=bos_token)
        doc_buffer.extend(token_lists)

    row_buffer = torch.empty((B, row_capacity), dtype=torch.long)
    cpu_buffer = torch.empty(2 * B * T, dtype=torch.long, pin_memory=use_cuda)
    cpu_inputs = cpu_buffer[:B * T].view(B, T)
    cpu_targets = cpu_buffer[B * T:].view(B, T)

    if use_cuda:
        gpu_buffer = torch.empty(2 * B * T, dtype=torch.long, device=resolved_device)
        inputs = gpu_buffer[:B * T].view(B, T)
        targets = gpu_buffer[B * T:].view(B, T)
    else:
        gpu_buffer = None
        inputs = cpu_inputs
        targets = cpu_targets

    while True:
        for row_idx in range(B):
            pos = 0
            while pos < row_capacity:
                while len(doc_buffer) < buffer_size:
                    refill_buffer()

                remaining = row_capacity - pos

                best_idx = -1
                best_len = 0
                for i, doc in enumerate(doc_buffer):
                    doc_len = len(doc)
                    if doc_len <= remaining and doc_len > best_len:
                        best_idx = i
                        best_len = doc_len

                if best_idx >= 0:
                    doc = doc_buffer.pop(best_idx)
                    row_buffer[row_idx, pos:pos + len(doc)] = torch.as_tensor(doc, dtype=torch.long)
                    pos += len(doc)
                else:
                    shortest_idx = min(range(len(doc_buffer)), key=lambda i: len(doc_buffer[i]))
                    doc = doc_buffer.pop(shortest_idx)
                    row_buffer[row_idx, pos:pos + remaining] = torch.as_tensor(doc[:remaining], dtype=torch.long)
                    pos += remaining

        cpu_inputs.copy_(row_buffer[:, :-1])
        cpu_targets.copy_(row_buffer[:, 1:])
        if use_cuda:
            gpu_buffer.copy_(cpu_buffer, non_blocking=True)
        yield inputs, targets, epoch


# ---------------------------------------------------------------------------
# Evaluation (DO NOT CHANGE METRIC DEFINITION)
# ---------------------------------------------------------------------------

@torch.no_grad()
def evaluate_bpb(model, tokenizer, batch_size, device="cuda", dataset=None, eval_tokens=EVAL_TOKENS):
    """
    Bits per byte (BPB): vocab size-independent evaluation metric.
    Sums per-token cross-entropy (in nats), sums target byte lengths,
    then converts nats/byte to bits/byte. Special tokens (byte length 0)
    are excluded from both sums.
    """
    dataset_name = _resolve_dataset_name(dataset or getattr(tokenizer, "dataset", None))
    token_bytes = get_token_bytes(device=device, dataset=dataset_name)
    val_loader = make_dataloader(
        tokenizer,
        batch_size,
        MAX_SEQ_LEN,
        "val",
        device=device,
        dataset=dataset_name,
    )
    steps = max(1, eval_tokens // (batch_size * MAX_SEQ_LEN))
    total_nats = 0.0
    total_bytes = 0
    for _ in range(steps):
        x, y, _ = next(val_loader)
        loss_flat = model(x, y, reduction="none").view(-1)
        y_flat = y.view(-1)
        nbytes = token_bytes[y_flat]
        mask = nbytes > 0
        total_nats += (loss_flat * mask).sum().item()
        total_bytes += nbytes.sum().item()
    if total_bytes == 0:
        raise RuntimeError("Evaluation produced zero target bytes; cannot compute BPB.")
    return total_nats / (math.log(2) * total_bytes)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description="Prepare data and tokenizer for autoresearch")
    parser.add_argument(
        "--dataset",
        choices=DATASET_CHOICES,
        default=None,
        help=(
            "Dataset profile to prepare. If omitted, resolves in order: "
            "AUTORESEARCH_DATASET, active_dataset.txt, then default tinystories."
        ),
    )
    args = parser.parse_args(argv)

    dataset_name = _resolve_dataset_name(args.dataset)

    print(f"Cache directory: {CACHE_DIR}")
    print(f"Dataset: {dataset_name}")
    print()

    try:
        download_data(dataset_name)
        print()
        train_tokenizer(dataset_name)
        _set_active_dataset(dataset_name)
    except (
        DatasetTransportError,
        DatasetIntegrityError,
        DatasetPlacementError,
        TokenizerCacheError,
    ) as exc:
        print(f"Error: {exc}")
        return 1

    print()
    print(f"Done! Ready to train. Active dataset is now '{dataset_name}'.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
