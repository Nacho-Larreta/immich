from __future__ import annotations

import hashlib
import json
import os
import stat
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from strict_evidence import (
    EvidenceValidationError,
    StrictJsonDocument,
    load_strict_json_document,
    require_enum,
    require_exact_keys,
    require_int,
    require_object,
    require_sha256,
    require_string,
)


ARTIFACT_FORMAT_SUFFIXES = {
    "csv": ".csv",
    "json": ".json",
    "jsonl": ".jsonl",
    "trace": ".trace",
}
DIRECTORY_HASH_DOMAIN = b"IMMICH-PHYSICAL-EVIDENCE-DIRECTORY-V1\0"
FILE_HASH_CHUNK_SIZE = 1024 * 1024


@dataclass(frozen=True)
class ArtifactDigest:
    sha256: str
    byte_count: int


class ArtifactVerifier:
    def __init__(self, evidence_root: Path) -> None:
        self._root = require_private_external_directory(evidence_root, "evidence_root")
        self._roles: set[str] = set()
        self._physical_digests: set[tuple[str, int]] = set()
        self.verified_count = 0

    def verify(
        self,
        raw: Any,
        *,
        expected_role: str,
        expected_format: str,
        allow_digest_reuse: bool = False,
    ) -> ArtifactDigest:
        location, role, artifact_format, expected_sha256, expected_bytes = (
            self._parse_record(raw, expected_role, expected_format)
        )

        artifact_path = self._root / f"{role}{ARTIFACT_FORMAT_SUFFIXES[artifact_format]}"
        digest = digest_artifact(artifact_path, artifact_format, location)
        if digest.sha256 != expected_sha256 or digest.byte_count != expected_bytes:
            raise EvidenceValidationError("artifact_integrity_mismatch", location)

        self._register(role, digest, location, allow_digest_reuse)
        return digest

    def verify_json(
        self,
        raw: Any,
        *,
        expected_role: str,
        allow_digest_reuse: bool = False,
    ) -> StrictJsonDocument:
        location, role, _, expected_sha256, expected_bytes = self._parse_record(
            raw,
            expected_role,
            "json",
        )
        path = self._root / f"{role}.json"
        document = load_strict_json_document(path, root=self._root, location=location)
        digest = ArtifactDigest(document.sha256, document.byte_count)
        if digest.sha256 != expected_sha256 or digest.byte_count != expected_bytes:
            raise EvidenceValidationError("artifact_integrity_mismatch", location)
        self._register(role, digest, location, allow_digest_reuse)
        return document

    def _parse_record(
        self,
        raw: Any,
        expected_role: str,
        expected_format: str,
    ) -> tuple[str, str, str, str, int]:
        location = f"artifact.{expected_role}"
        record = require_object(raw, location)
        require_exact_keys(record, {"role", "format", "sha256", "byteCount"}, location)
        role = require_string(record["role"], f"{location}.role")
        artifact_format = require_enum(
            record["format"],
            set(ARTIFACT_FORMAT_SUFFIXES),
            f"{location}.format",
        )
        expected_sha256 = require_sha256(record["sha256"], f"{location}.sha256")
        expected_bytes = require_int(
            record["byteCount"],
            f"{location}.byteCount",
            minimum=1,
        )
        if role != expected_role or artifact_format != expected_format:
            raise EvidenceValidationError("artifact_identity_mismatch", location)
        if role in self._roles:
            raise EvidenceValidationError("artifact_role_reused", location)
        return location, role, artifact_format, expected_sha256, expected_bytes

    def _register(
        self,
        role: str,
        digest: ArtifactDigest,
        location: str,
        allow_digest_reuse: bool,
    ) -> None:
        digest_identity = (digest.sha256, digest.byte_count)
        if not allow_digest_reuse and digest_identity in self._physical_digests:
            raise EvidenceValidationError("artifact_digest_reused", location)
        self._roles.add(role)
        if not allow_digest_reuse:
            self._physical_digests.add(digest_identity)
        self.verified_count += 1


def digest_artifact(
    artifact_path: Path,
    artifact_format: str,
    location: str,
) -> ArtifactDigest:
    try:
        artifact_status = artifact_path.lstat()
    except OSError as error:
        raise EvidenceValidationError("artifact_missing", location) from error
    if stat.S_ISLNK(artifact_status.st_mode):
        raise EvidenceValidationError("artifact_symlink_forbidden", location)

    if artifact_format == "trace":
        if not stat.S_ISDIR(artifact_status.st_mode):
            raise EvidenceValidationError("trace_must_be_directory", location)
        return _digest_directory(artifact_path, location)

    if not stat.S_ISREG(artifact_status.st_mode):
        raise EvidenceValidationError("export_must_be_regular_file", location)
    return _digest_file(artifact_path, location)


def digest_regular_file(path: Path, location: str) -> ArtifactDigest:
    try:
        status = path.lstat()
    except OSError as error:
        raise EvidenceValidationError("artifact_missing", location) from error
    if stat.S_ISLNK(status.st_mode):
        raise EvidenceValidationError("artifact_symlink_forbidden", location)
    if not stat.S_ISREG(status.st_mode):
        raise EvidenceValidationError("export_must_be_regular_file", location)
    return _digest_file(path, location)


def _digest_file(path: Path, location: str) -> ArtifactDigest:
    digest = hashlib.sha256()
    byte_count = 0
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb", closefd=True) as source:
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise EvidenceValidationError("artifact_changed_type", location)
            while chunk := source.read(FILE_HASH_CHUNK_SIZE):
                digest.update(chunk)
                byte_count += len(chunk)
            after = os.fstat(source.fileno())
            path_after = path.lstat()
            if (
                _snapshot(before) != _snapshot(after)
                or _identity(after) != _identity(path_after)
                or byte_count != after.st_size
            ):
                raise EvidenceValidationError("artifact_changed_while_hashing", location)
    except OSError as error:
        raise EvidenceValidationError("artifact_unreadable", location) from error
    if byte_count == 0:
        raise EvidenceValidationError("artifact_empty", location)
    return ArtifactDigest(digest.hexdigest(), byte_count)


def _digest_directory(path: Path, location: str) -> ArtifactDigest:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise EvidenceValidationError("trace_unreadable", location) from error
    try:
        root_before = os.fstat(descriptor)
        digest = hashlib.sha256(DIRECTORY_HASH_DOMAIN)
        byte_count = _digest_directory_descriptor(
            descriptor,
            b"",
            digest,
            location,
        )
        root_after = os.fstat(descriptor)
        path_after = path.lstat()
        if _snapshot(root_before) != _snapshot(root_after) or _identity(root_after) != _identity(path_after):
            raise EvidenceValidationError("trace_changed_while_hashing", location)
    except OSError as error:
        raise EvidenceValidationError("trace_unreadable", location) from error
    finally:
        os.close(descriptor)
    if byte_count == 0:
        raise EvidenceValidationError("artifact_empty", location)
    return ArtifactDigest(digest.hexdigest(), byte_count)


def _digest_directory_descriptor(
    descriptor: int,
    prefix: bytes,
    digest: Any,
    location: str,
) -> int:
    names_before = sorted(os.listdir(descriptor))
    byte_count = 0
    for name in names_before:
        if name in {".", ".."}:
            raise EvidenceValidationError("trace_invalid_entry", location)
        name_bytes = os.fsencode(name)
        relative = name_bytes if not prefix else prefix + b"/" + name_bytes
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            raise EvidenceValidationError("trace_symlink_forbidden", location)
        if stat.S_ISDIR(before.st_mode):
            _update_tree_entry_header(digest, b"D", relative, 0)
            child_flags = (
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )
            child = os.open(name, child_flags, dir_fd=descriptor)
            try:
                if _identity(before) != _identity(os.fstat(child)):
                    raise EvidenceValidationError("trace_changed_while_hashing", location)
                byte_count += _digest_directory_descriptor(child, relative, digest, location)
            finally:
                os.close(child)
        elif stat.S_ISREG(before.st_mode):
            _update_tree_entry_header(digest, b"F", relative, before.st_size)
            file_descriptor = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(file_descriptor)
                if _snapshot(before) != _snapshot(opened):
                    raise EvidenceValidationError("trace_changed_while_hashing", location)
                file_digest = _digest_open_file(file_descriptor, location)
                digest.update(bytes.fromhex(file_digest.sha256))
                byte_count += file_digest.byte_count
            finally:
                os.close(file_descriptor)
        else:
            raise EvidenceValidationError("trace_special_file_forbidden", location)
        after = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if _snapshot(before) != _snapshot(after):
            raise EvidenceValidationError("trace_changed_while_hashing", location)
    if names_before != sorted(os.listdir(descriptor)):
        raise EvidenceValidationError("trace_changed_while_hashing", location)
    return byte_count


def _update_tree_entry_header(
    digest: Any,
    kind: bytes,
    relative: bytes,
    size: int,
) -> None:
    digest.update(kind)
    digest.update(struct.pack(">I", len(relative)))
    digest.update(relative)
    digest.update(struct.pack(">Q", size))


def _digest_open_file(descriptor: int, location: str) -> ArtifactDigest:
    before = os.fstat(descriptor)
    digest = hashlib.sha256()
    byte_count = 0
    while chunk := os.read(descriptor, FILE_HASH_CHUNK_SIZE):
        digest.update(chunk)
        byte_count += len(chunk)
    after = os.fstat(descriptor)
    if _snapshot(before) != _snapshot(after) or byte_count != after.st_size:
        raise EvidenceValidationError("trace_changed_while_hashing", location)
    if byte_count == 0:
        raise EvidenceValidationError("artifact_empty", location)
    return ArtifactDigest(digest.hexdigest(), byte_count)


def _identity(status: os.stat_result) -> tuple[int, int]:
    return status.st_dev, status.st_ino


def _snapshot(status: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        status.st_dev,
        status.st_ino,
        status.st_mode,
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
    )


def require_private_external_directory(path: Path, location: str) -> Path:
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
    _reject_git_ancestor(resolved, location)
    return resolved


def prepare_private_external_parent(path: Path, location: str) -> Path:
    requested = path.expanduser().absolute()
    parent = requested.parent
    parent_existed = parent.exists()
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if parent.is_symlink():
        raise EvidenceValidationError("symlink_directory_forbidden", location)
    resolved_parent = parent.resolve(strict=True)
    _reject_git_ancestor(resolved_parent, location)
    if not parent_existed:
        os.chmod(resolved_parent, 0o700)
    if stat.S_IMODE(resolved_parent.stat().st_mode) & 0o077:
        raise EvidenceValidationError("directory_not_private", location)
    return resolved_parent / requested.name


def _reject_git_ancestor(path: Path, location: str) -> None:
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists():
            raise EvidenceValidationError("evidence_inside_git_worktree", location)


def write_private_json_exclusive(path: Path, value: Any) -> None:
    target = prepare_private_external_parent(path, "output")
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(target, flags, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        raise EvidenceValidationError("output_not_created", "output") from error
