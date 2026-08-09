from __future__ import annotations

import json
import hashlib
import math
import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
SOURCE_REVISION_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
VERSION_PATTERN = re.compile(r"[0-9]+(?:\.[0-9]+){1,3}\Z")
BUNDLE_IDENTIFIER_PATTERN = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+\Z"
)
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_JSON_DEPTH = 32


class EvidenceValidationError(ValueError):
    def __init__(self, code: str, location: str) -> None:
        super().__init__(f"{code} at {location}")
        self.code = code
        self.location = location


class DuplicateJsonKeyError(EvidenceValidationError):
    pass


@dataclass(frozen=True)
class StrictJsonDocument:
    value: dict[str, Any]
    sha256: str
    byte_count: int


def load_strict_json(
    path: Path,
    *,
    root: Path | None = None,
    location: str = "manifest",
) -> dict[str, Any]:
    return load_strict_json_document(path, root=root, location=location).value


def load_strict_json_document(
    path: Path,
    *,
    root: Path | None = None,
    location: str = "manifest",
) -> StrictJsonDocument:
    safe_root = _validate_private_root(root or path.parent, location)
    requested = path.expanduser().absolute()
    try:
        if requested.parent.resolve(strict=True) != safe_root:
            raise ValueError
    except (OSError, ValueError) as error:
        raise EvidenceValidationError("json_outside_allowed_root", location) from error

    root_descriptor = -1
    try:
        root_descriptor = os.open(
            safe_root,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        descriptor = os.open(
            requested.name,
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=root_descriptor,
        )
    except OSError as error:
        raise EvidenceValidationError("json_unreadable", location) from error
    finally:
        if root_descriptor >= 0:
            os.close(root_descriptor)

    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise EvidenceValidationError("json_not_regular_file", location)
        if stat.S_IMODE(before.st_mode) != 0o600:
            raise EvidenceValidationError("json_not_private", location)
        if before.st_size > MAX_JSON_BYTES:
            raise EvidenceValidationError("json_oversize", location)
        payload = _read_bounded(descriptor, location)
        after = os.fstat(descriptor)
        try:
            path_after = requested.lstat()
        except OSError as error:
            raise EvidenceValidationError("json_changed_while_reading", location) from error
        if (
            _file_snapshot(before) != _file_snapshot(after)
            or (after.st_dev, after.st_ino) != (path_after.st_dev, path_after.st_ino)
            or len(payload) != after.st_size
        ):
            raise EvidenceValidationError("json_changed_while_reading", location)
    finally:
        os.close(descriptor)

    value = parse_strict_json_bytes(payload, location)

    parsed = require_object(value, location)
    return StrictJsonDocument(parsed, hashlib.sha256(payload).hexdigest(), len(payload))


def parse_strict_json_bytes(payload: bytes, location: str) -> Any:
    try:
        text = payload.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_non_finite_number,
        )
        _validate_json_depth(value, location)
        return value
    except EvidenceValidationError:
        raise
    except UnicodeError as error:
        raise EvidenceValidationError("json_invalid_utf8", location) from error
    except json.JSONDecodeError as error:
        raise EvidenceValidationError("json_malformed", location) from error
    except RecursionError as error:
        raise EvidenceValidationError("json_too_deep", location) from error
    except ValueError as error:
        raise EvidenceValidationError("json_malformed", location) from error


def _validate_private_root(path: Path, location: str) -> Path:
    requested = path.expanduser().absolute()
    if requested.is_symlink():
        raise EvidenceValidationError("symlink_directory_forbidden", location)
    try:
        resolved = requested.resolve(strict=True)
        status = resolved.stat()
    except OSError as error:
        raise EvidenceValidationError("directory_unavailable", location) from error
    if not stat.S_ISDIR(status.st_mode):
        raise EvidenceValidationError("expected_directory", location)
    if stat.S_IMODE(status.st_mode) & 0o077:
        raise EvidenceValidationError("directory_not_private", location)
    for candidate in (resolved, *resolved.parents):
        if (candidate / ".git").exists():
            raise EvidenceValidationError("evidence_inside_git_worktree", location)
    return resolved


def _read_bounded(descriptor: int, location: str) -> bytes:
    chunks: list[bytes] = []
    byte_count = 0
    while chunk := os.read(descriptor, min(1024 * 1024, MAX_JSON_BYTES + 1 - byte_count)):
        chunks.append(chunk)
        byte_count += len(chunk)
        if byte_count > MAX_JSON_BYTES:
            raise EvidenceValidationError("json_oversize", location)
    return b"".join(chunks)


def _file_snapshot(status: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        status.st_dev,
        status.st_ino,
        status.st_mode,
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
    )


def _validate_json_depth(value: Any, location: str) -> None:
    stack = [(value, 1)]
    while stack:
        current, depth = stack.pop()
        if depth > MAX_JSON_DEPTH:
            raise EvidenceValidationError("json_too_deep", location)
        if type(current) is dict:
            stack.extend((child, depth + 1) for child in current.values())
        elif type(current) is list:
            stack.extend((child, depth + 1) for child in current)


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJsonKeyError("duplicate_json_key", key)
        result[key] = value
    return result


def _reject_non_finite_number(value: str) -> None:
    raise EvidenceValidationError("non_finite_number", value)


def require_object(value: Any, location: str) -> dict[str, Any]:
    if type(value) is not dict:
        raise EvidenceValidationError("expected_object", location)
    return value


def require_exact_keys(
    value: Mapping[str, Any],
    expected: Iterable[str],
    location: str,
) -> None:
    expected_set = set(expected)
    actual_set = set(value)
    if actual_set != expected_set:
        raise EvidenceValidationError("unexpected_or_missing_keys", location)


def require_list(value: Any, location: str) -> list[Any]:
    if type(value) is not list:
        raise EvidenceValidationError("expected_list", location)
    return value


def require_string(value: Any, location: str) -> str:
    if type(value) is not str or not value:
        raise EvidenceValidationError("expected_nonempty_string", location)
    return value


def require_enum(value: Any, allowed: set[str], location: str) -> str:
    parsed = require_string(value, location)
    if parsed not in allowed:
        raise EvidenceValidationError("unsupported_enum_value", location)
    return parsed


def require_bool(value: Any, location: str) -> bool:
    if type(value) is not bool:
        raise EvidenceValidationError("expected_boolean", location)
    return value


def require_int(
    value: Any,
    location: str,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    if type(value) is not int:
        raise EvidenceValidationError("expected_integer", location)
    if minimum is not None and value < minimum:
        raise EvidenceValidationError("integer_below_minimum", location)
    if maximum is not None and value > maximum:
        raise EvidenceValidationError("integer_above_maximum", location)
    return value


def require_number(
    value: Any,
    location: str,
    *,
    minimum: float | None = None,
    maximum: float | None = None,
) -> float:
    if type(value) not in (int, float):
        raise EvidenceValidationError("expected_number", location)
    parsed = float(value)
    if not math.isfinite(parsed):
        raise EvidenceValidationError("non_finite_number", location)
    if minimum is not None and parsed < minimum:
        raise EvidenceValidationError("number_below_minimum", location)
    if maximum is not None and parsed > maximum:
        raise EvidenceValidationError("number_above_maximum", location)
    return parsed


def require_nullable_number(value: Any, location: str) -> float | None:
    if value is None:
        return None
    return require_number(value, location)


def require_nullable_int(value: Any, location: str) -> int | None:
    if value is None:
        return None
    return require_int(value, location)


def require_sha256(value: Any, location: str) -> str:
    parsed = require_string(value, location)
    if SHA256_PATTERN.fullmatch(parsed) is None:
        raise EvidenceValidationError("invalid_sha256", location)
    return parsed


def require_source_revision(value: Any, location: str) -> str:
    parsed = require_string(value, location)
    if SOURCE_REVISION_PATTERN.fullmatch(parsed) is None:
        raise EvidenceValidationError("invalid_source_revision", location)
    return parsed


def require_version(value: Any, location: str) -> str:
    parsed = require_string(value, location)
    if VERSION_PATTERN.fullmatch(parsed) is None:
        raise EvidenceValidationError("invalid_version", location)
    return parsed


def require_bundle_identifier(value: Any, location: str) -> str:
    parsed = require_string(value, location)
    if BUNDLE_IDENTIFIER_PATTERN.fullmatch(parsed) is None:
        raise EvidenceValidationError("invalid_bundle_identifier", location)
    return parsed
