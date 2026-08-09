#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import random
import secrets
import shutil
import stat
import struct
import subprocess
import sys
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


DEFAULT_OUTPUT_DIRECTORY = Path("/private/tmp/immich-t093-fixtures")
PAYLOAD_SEED = "immich-t093-free-box-v1"
WRITE_CHUNK_SIZE = 4 * 1024 * 1024
FREE_SPACE_HEADROOM_BYTES = 64 * 1024 * 1024
ISO_BMFF_BOX_HEADER_SIZE = 8
MAX_STANDARD_BOX_SIZE = (1 << 32) - 1
FIXTURE_SPECS = (
    ("fixture-256", 268_435_456),
    ("fixture-1024", 1_073_741_824),
)


class UnsafeOutputDirectoryError(ValueError):
    pass


@dataclass(frozen=True)
class FixtureSpec:
    label: str
    target_size: int

    @property
    def filename(self) -> str:
        return f"{self.label}.mp4"


@dataclass(frozen=True)
class FileIdentity:
    device: int
    inode: int


@dataclass(frozen=True)
class FixtureResult:
    spec: FixtureSpec
    path: Path
    sha256: str
    allocated_bytes: int


@dataclass(frozen=True)
class VideoProbe:
    stream_types: list[str]


@dataclass(frozen=True)
class StagedFile:
    name: str
    descriptor: int
    identity: FileIdentity


@dataclass(frozen=True)
class StagedFixture:
    spec: FixtureSpec
    file: StagedFile
    sha256: str
    allocated_bytes: int


def validate_output_directory(output_directory: Path) -> Path:
    requested_output = output_directory.expanduser().absolute()
    if requested_output.is_symlink():
        raise UnsafeOutputDirectoryError(
            f"Output directory cannot be a symlink: {requested_output}"
        )

    resolved_output = requested_output.resolve()
    if ".git" in resolved_output.parts:
        raise UnsafeOutputDirectoryError(
            f"Output cannot be inside Git metadata: {resolved_output}"
        )

    for candidate in (resolved_output, *resolved_output.parents):
        if (candidate / ".git").exists():
            raise UnsafeOutputDirectoryError(
                f"Output cannot be inside a Git worktree: {resolved_output}"
            )

    return resolved_output


def prepare_output_directory(output_directory: Path) -> Path:
    safe_output, directory_descriptor = _prepare_and_open_output_directory(
        output_directory
    )
    os.close(directory_descriptor)
    return safe_output


def _prepare_and_open_output_directory(output_directory: Path) -> tuple[Path, int]:
    safe_output = validate_output_directory(output_directory)
    safe_output.mkdir(parents=True, exist_ok=True, mode=0o700)
    if safe_output.is_symlink():
        raise UnsafeOutputDirectoryError(
            f"Output directory cannot be a symlink: {safe_output}"
        )

    with ExitStack() as failure_cleanup:
        directory_descriptor = _open_directory(safe_output)
        failure_cleanup.callback(os.close, directory_descriptor)
        os.fchmod(directory_descriptor, 0o700)
        directory_status = os.fstat(directory_descriptor)
        if not stat.S_ISDIR(directory_status.st_mode):
            raise UnsafeOutputDirectoryError(f"Output is not a directory: {safe_output}")
        if stat.S_IMODE(directory_status.st_mode) != 0o700:
            raise UnsafeOutputDirectoryError(
                f"Output directory must have mode 0700: {safe_output}"
            )
        if _descriptor_identity(directory_descriptor) != _path_identity(safe_output):
            raise UnsafeOutputDirectoryError(
                f"Output directory changed while it was being opened: {safe_output}"
            )
        validate_output_directory(safe_output)
        failure_cleanup.pop_all()
    return safe_output, directory_descriptor


def generate_fixtures(
    output_directory: Path,
    ffmpeg: str = "ffmpeg",
    ffprobe: str = "ffprobe",
) -> list[FixtureResult]:
    safe_output, output_descriptor = _prepare_and_open_output_directory(
        output_directory
    )
    with ExitStack() as resources:
        resources.callback(os.close, output_descriptor)
        specs = [
            FixtureSpec(label, target_size) for label, target_size in FIXTURE_SPECS
        ]
        _require_free_space(
            output_descriptor,
            _required_free_space(specs),
        )
        _reject_existing_outputs(
            output_descriptor,
            [*(spec.filename for spec in specs), "manifest.json"],
        )

        staging_name, staging_descriptor = _create_staging_directory(output_descriptor)
        resources.callback(_remove_staging_directory, output_descriptor, staging_name)
        resources.callback(os.close, staging_descriptor)

        base = _create_staged_file(staging_descriptor, "base")
        resources.callback(_unlink_staged_file, staging_descriptor, base.name)
        resources.callback(os.close, base.descriptor)
        _write_all(base.descriptor, _generate_base_video(ffmpeg))
        _probe_video_descriptor(base.descriptor, ffprobe)

        staged_fixtures: list[StagedFixture] = []
        for spec in specs:
            staged_file = _create_staged_file(staging_descriptor, spec.label)
            resources.callback(
                _unlink_staged_file,
                staging_descriptor,
                staged_file.name,
            )
            resources.callback(os.close, staged_file.descriptor)
            sha256, allocated_bytes = _append_free_box(
                base.descriptor,
                staged_file.descriptor,
                spec.target_size,
                seed=f"{PAYLOAD_SEED}:{spec.label}",
            )
            _probe_video_descriptor(staged_file.descriptor, ffprobe)
            staged_fixtures.append(
                StagedFixture(
                    spec=spec,
                    file=staged_file,
                    sha256=sha256,
                    allocated_bytes=allocated_bytes,
                )
            )

        manifest = _create_staged_file(staging_descriptor, "manifest")
        resources.callback(_unlink_staged_file, staging_descriptor, manifest.name)
        resources.callback(os.close, manifest.descriptor)
        manifest_bytes = _serialize_manifest(staged_fixtures)
        _write_all(manifest.descriptor, manifest_bytes)

        results = _publish_fixtures(
            safe_output,
            output_descriptor,
            staging_descriptor,
            staged_fixtures,
        )
        _publish_file(
            staging_descriptor,
            manifest,
            output_descriptor,
            "manifest.json",
        )

    return results


def _generate_base_video(ffmpeg: str) -> bytes:
    _require_executable(ffmpeg)
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=64x64:rate=1:duration=1",
        "-map",
        "0:v:0",
        "-an",
        "-c:v",
        "mpeg4",
        "-q:v",
        "5",
        "-pix_fmt",
        "yuv420p",
        "-map_metadata",
        "-1",
        "-metadata",
        "encoder=",
        "-fflags",
        "+bitexact",
        "-flags:v",
        "+bitexact",
        "-movflags",
        "+frag_keyframe+empty_moov",
        "-f",
        "mp4",
        "pipe:1",
    ]
    return _run_binary_checked(
        command,
        "ffmpeg failed to generate the synthetic MP4",
    ).stdout


def _append_free_box(
    base_descriptor: int,
    output_descriptor: int,
    target_size: int,
    seed: str,
) -> tuple[str, int]:
    base_size = os.fstat(base_descriptor).st_size
    free_box_size = target_size - base_size
    if free_box_size < ISO_BMFF_BOX_HEADER_SIZE:
        raise ValueError("Target size must leave room for an ISO-BMFF free box")
    if free_box_size > MAX_STANDARD_BOX_SIZE:
        raise ValueError("ISO-BMFF free box exceeds the standard 32-bit box size")

    digest = hashlib.sha256()
    os.lseek(base_descriptor, 0, os.SEEK_SET)
    os.lseek(output_descriptor, 0, os.SEEK_SET)
    _copy_descriptor(base_descriptor, output_descriptor, digest)

    free_box_header = struct.pack(">I4s", free_box_size, b"free")
    _write_bytes(output_descriptor, free_box_header)
    digest.update(free_box_header)
    _write_deterministic_payload(
        output_descriptor,
        digest,
        random.Random(seed),
        free_box_size - ISO_BMFF_BOX_HEADER_SIZE,
    )
    os.fsync(output_descriptor)

    file_status = os.fstat(output_descriptor)
    if file_status.st_size != target_size:
        raise RuntimeError("Fixture has the wrong size")
    allocated_bytes = _assert_fully_allocated(file_status)
    return digest.hexdigest(), allocated_bytes


def _probe_video_descriptor(descriptor: int, ffprobe: str) -> VideoProbe:
    _require_executable(ffprobe)
    os.lseek(descriptor, 0, os.SEEK_SET)
    command = [
        ffprobe,
        "-v",
        "error",
        "-show_entries",
        "stream=codec_type",
        "-of",
        "json",
        f"/dev/fd/{descriptor}",
    ]
    completed = _run_checked(
        command,
        "ffprobe rejected a staged fixture",
        pass_fds=(descriptor,),
    )
    try:
        payload = json.loads(completed.stdout)
        stream_types = [stream["codec_type"] for stream in payload["streams"]]
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise RuntimeError("ffprobe returned an unexpected response") from error

    if stream_types != ["video"]:
        raise RuntimeError("Fixture must contain exactly one video stream and no audio")
    return VideoProbe(stream_types=stream_types)


def _serialize_manifest(fixtures: Sequence[StagedFixture]) -> bytes:
    manifest = {
        "schemaVersion": 1,
        "fixtures": [
            {
                "label": fixture.spec.label,
                "file": fixture.spec.filename,
                "sizeBytes": fixture.spec.target_size,
                "allocatedBytes": fixture.allocated_bytes,
                "sha256": fixture.sha256,
            }
            for fixture in fixtures
        ],
    }
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _publish_fixtures(
    output_path: Path,
    output_descriptor: int,
    staging_descriptor: int,
    fixtures: Sequence[StagedFixture],
) -> list[FixtureResult]:
    results: list[FixtureResult] = []
    for fixture in fixtures:
        _publish_file(
            staging_descriptor,
            fixture.file,
            output_descriptor,
            fixture.spec.filename,
        )
        results.append(
            FixtureResult(
                spec=fixture.spec,
                path=output_path / fixture.spec.filename,
                sha256=fixture.sha256,
                allocated_bytes=fixture.allocated_bytes,
            )
        )
    return results


def _publish_file(
    staging_descriptor: int,
    staged_file: StagedFile,
    output_descriptor: int,
    final_name: str,
) -> None:
    os.link(
        staged_file.name,
        final_name,
        src_dir_fd=staging_descriptor,
        dst_dir_fd=output_descriptor,
        follow_symlinks=False,
    )
    os.fsync(output_descriptor)
    published_descriptor = _open_existing_file(output_descriptor, final_name)
    try:
        if _descriptor_identity(published_descriptor) != staged_file.identity:
            raise RuntimeError(f"Published file identity mismatch: {final_name}")
        os.fsync(published_descriptor)
    finally:
        os.close(published_descriptor)
    os.unlink(staged_file.name, dir_fd=staging_descriptor)


def _create_staging_directory(output_descriptor: int) -> tuple[str, int]:
    for _ in range(16):
        name = f".t093-{secrets.token_hex(16)}"
        try:
            os.mkdir(name, 0o700, dir_fd=output_descriptor)
        except FileExistsError:
            continue
        with ExitStack() as failure_cleanup:
            failure_cleanup.callback(
                _remove_staging_directory,
                output_descriptor,
                name,
            )
            descriptor = _open_directory_at(output_descriptor, name)
            failure_cleanup.callback(os.close, descriptor)
            os.fchmod(descriptor, 0o700)
            failure_cleanup.pop_all()
            return name, descriptor
    raise RuntimeError("Unable to create a unique staging directory")


def _create_staged_file(directory_descriptor: int, prefix: str) -> StagedFile:
    for _ in range(16):
        name = f".{prefix}-{secrets.token_hex(16)}.tmp"
        flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(
                name,
                flags,
                0o600,
                dir_fd=directory_descriptor,
            )
        except FileExistsError:
            continue
        with ExitStack() as failure_cleanup:
            failure_cleanup.callback(
                _unlink_staged_file,
                directory_descriptor,
                name,
            )
            failure_cleanup.callback(os.close, descriptor)
            os.fchmod(descriptor, 0o600)
            staged_file = StagedFile(
                name=name,
                descriptor=descriptor,
                identity=_descriptor_identity(descriptor),
            )
            failure_cleanup.pop_all()
            return staged_file
    raise RuntimeError("Unable to create a unique staged file")


def _open_directory(path: Path) -> int:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return os.open(path, flags)


def _open_directory_at(parent_descriptor: int, name: str) -> int:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return os.open(name, flags, dir_fd=parent_descriptor)


def _open_existing_file(directory_descriptor: int, name: str) -> int:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    return os.open(name, flags, dir_fd=directory_descriptor)


def _descriptor_identity(descriptor: int) -> FileIdentity:
    file_status = os.fstat(descriptor)
    return FileIdentity(device=file_status.st_dev, inode=file_status.st_ino)


def _path_identity(path: Path) -> FileIdentity:
    file_status = path.stat(follow_symlinks=False)
    return FileIdentity(device=file_status.st_dev, inode=file_status.st_ino)


def _write_all(descriptor: int, content: bytes) -> None:
    os.lseek(descriptor, 0, os.SEEK_SET)
    _write_bytes(descriptor, content)
    os.fsync(descriptor)


def _write_bytes(descriptor: int, content: bytes) -> None:
    remaining = memoryview(content)
    while remaining:
        written = os.write(descriptor, remaining)
        if written == 0:
            raise RuntimeError("File write made no progress")
        remaining = remaining[written:]


def _copy_descriptor(source: int, destination: int, digest) -> None:
    while chunk := os.read(source, WRITE_CHUNK_SIZE):
        _write_bytes(destination, chunk)
        digest.update(chunk)


def _write_deterministic_payload(
    descriptor: int,
    digest,
    random_source: random.Random,
    byte_count: int,
) -> None:
    remaining = byte_count
    while remaining:
        chunk_size = min(remaining, WRITE_CHUNK_SIZE)
        chunk = random_source.randbytes(chunk_size)
        _write_bytes(descriptor, chunk)
        digest.update(chunk)
        remaining -= chunk_size


def _assert_fully_allocated(file_status: os.stat_result) -> int:
    if not hasattr(file_status, "st_blocks"):
        raise RuntimeError(
            "The current platform cannot report physical allocation with st_blocks"
        )
    allocated_bytes = file_status.st_blocks * 512
    if allocated_bytes < file_status.st_size:
        raise RuntimeError(
            "Fixture is sparse or compressed: "
            f"{allocated_bytes} allocated bytes for "
            f"{file_status.st_size} logical bytes"
        )
    return allocated_bytes


def _reject_existing_outputs(directory_descriptor: int, names: Sequence[str]) -> None:
    existing = [name for name in names if _entry_exists(directory_descriptor, name)]
    if existing:
        raise FileExistsError(
            f"Refusing to overwrite existing output: {', '.join(existing)}"
        )


def _entry_exists(directory_descriptor: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def _unlink_staged_file(directory_descriptor: int, name: str) -> None:
    try:
        os.unlink(name, dir_fd=directory_descriptor)
    except FileNotFoundError:
        pass


def _remove_staging_directory(output_descriptor: int, name: str) -> None:
    try:
        os.rmdir(name, dir_fd=output_descriptor)
    except FileNotFoundError:
        pass


def _require_executable(executable: str) -> None:
    if shutil.which(executable) is None:
        raise RuntimeError(f"Required executable is not available: {executable}")


def _run_binary_checked(
    command: list[str],
    failure_message: str,
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(command, check=True, capture_output=True)
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or b"").decode(errors="replace").strip()
        raise RuntimeError(f"{failure_message}: {detail}") from error


def _run_checked(
    command: list[str],
    failure_message: str,
    pass_fds: tuple[int, ...] = (),
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            pass_fds=pass_fds,
        )
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip()
        raise RuntimeError(f"{failure_message}: {detail}") from error


def _require_free_space(directory_descriptor: int, required_bytes: int) -> None:
    file_system_status = os.fstatvfs(directory_descriptor)
    available_bytes = file_system_status.f_bavail * file_system_status.f_frsize
    if available_bytes < required_bytes:
        raise RuntimeError(
            f"Insufficient free space: need {required_bytes} bytes, "
            f"have {available_bytes} bytes"
        )


def _required_free_space(specs: Sequence[FixtureSpec]) -> int:
    return sum(spec.target_size for spec in specs) + FREE_SPACE_HEADROOM_BYTES


def _build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate exact-size synthetic MP4 fixtures for T093"
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIRECTORY,
        help=f"destination directory (default: {DEFAULT_OUTPUT_DIRECTORY})",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _build_argument_parser().parse_args(argv)
    try:
        results = generate_fixtures(arguments.output_dir)
    except (
        FileExistsError,
        RuntimeError,
        UnsafeOutputDirectoryError,
        ValueError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    for result in results:
        print(
            f"{result.spec.label}: size={result.spec.target_size} "
            f"allocated={result.allocated_bytes} sha256={result.sha256}"
        )
    print(f"manifest: {results[0].path.parent / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
