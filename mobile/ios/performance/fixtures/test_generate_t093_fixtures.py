import hashlib
import json
import os
import shutil
import stat
import struct
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest.mock import patch

from generate_t093_fixtures import (
    FIXTURE_SPECS,
    FREE_SPACE_HEADROOM_BYTES,
    FileIdentity,
    FixtureSpec,
    StagedFile,
    StagedFixture,
    UnsafeOutputDirectoryError,
    _append_free_box,
    _assert_fully_allocated,
    _create_staging_directory,
    _generate_base_video,
    _open_directory,
    _probe_video_descriptor,
    _publish_file,
    _required_free_space,
    _serialize_manifest,
    generate_fixtures,
    prepare_output_directory,
    validate_output_directory,
)


class FreeBoxWriterTest(unittest.TestCase):
    def test_appends_deterministic_non_compressible_free_box_to_exact_size(self) -> None:
        target_size = 128 * 1024
        with (
            tempfile.TemporaryFile(dir="/private/tmp") as base,
            tempfile.TemporaryFile(dir="/private/tmp") as first,
            tempfile.TemporaryFile(dir="/private/tmp") as second,
        ):
            base_bytes = b"synthetic-mp4-base"
            base.write(base_bytes)
            base.flush()

            first_sha, _ = _append_free_box(
                base.fileno(),
                first.fileno(),
                target_size,
                "t093-test-seed",
            )
            second_sha, _ = _append_free_box(
                base.fileno(),
                second.fileno(),
                target_size,
                "t093-test-seed",
            )

            self.assertEqual(target_size, os.fstat(first.fileno()).st_size)
            self.assertEqual(first_sha, second_sha)
            first.seek(0)
            fixture_bytes = first.read()
            self.assertEqual(hashlib.sha256(fixture_bytes).hexdigest(), first_sha)

        free_box_size, free_box_type = struct.unpack(
            ">I4s",
            fixture_bytes[len(base_bytes) : len(base_bytes) + 8],
        )
        self.assertEqual(target_size - len(base_bytes), free_box_size)
        self.assertEqual(b"free", free_box_type)
        payload = fixture_bytes[len(base_bytes) + 8 :]
        self.assertGreater(len(zlib.compress(payload)), len(payload) * 0.99)

    def test_rejects_target_without_room_for_free_box(self) -> None:
        with (
            tempfile.TemporaryFile(dir="/private/tmp") as base,
            tempfile.TemporaryFile(dir="/private/tmp") as output,
        ):
            base.write(b"base")
            base.flush()

            with self.assertRaisesRegex(ValueError, "free box"):
                _append_free_box(base.fileno(), output.fileno(), 11, "seed")

    def test_rejects_sparse_output_during_allocation_check(self) -> None:
        with tempfile.TemporaryFile(dir="/private/tmp") as sparse:
            sparse.seek(32 * 1024 * 1024 - 1)
            sparse.write(b"\0")
            sparse.flush()

            with self.assertRaisesRegex(RuntimeError, "sparse or compressed"):
                _assert_fully_allocated(os.fstat(sparse.fileno()))


class OutputGuardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def test_rejects_output_below_git_marker(self) -> None:
        (self.root / ".git").mkdir()

        with self.assertRaises(UnsafeOutputDirectoryError):
            validate_output_directory(self.root / "fixtures")

    def test_rejects_git_metadata_path(self) -> None:
        with self.assertRaises(UnsafeOutputDirectoryError):
            validate_output_directory(self.root / ".git" / "fixtures")

    def test_rejects_symlink_output_directory(self) -> None:
        real_directory = self.root / "real"
        real_directory.mkdir()
        symlink = self.root / "linked"
        symlink.symlink_to(real_directory, target_is_directory=True)

        with self.assertRaises(UnsafeOutputDirectoryError):
            prepare_output_directory(symlink)

    def test_prepares_private_output_directory(self) -> None:
        output = prepare_output_directory(self.root / "fixtures")

        self.assertFalse(output.is_symlink())
        self.assertEqual(0o700, stat.S_IMODE(output.stat().st_mode))


class ManifestTest(unittest.TestCase):
    def test_serializes_stable_sha256_manifest_with_fixture_labels(self) -> None:
        fixtures = [
            self._staged_fixture("fixture-256", 256, "a" * 64),
            self._staged_fixture("fixture-1024", 1024, "b" * 64),
        ]

        parsed = json.loads(_serialize_manifest(fixtures))

        self.assertEqual(1, parsed["schemaVersion"])
        self.assertEqual(
            ["fixture-256", "fixture-1024"],
            [item["label"] for item in parsed["fixtures"]],
        )
        self.assertEqual(["a" * 64, "b" * 64], [item["sha256"] for item in parsed["fixtures"]])

    @staticmethod
    def _staged_fixture(label: str, size: int, sha256: str) -> StagedFixture:
        return StagedFixture(
            spec=FixtureSpec(label, size),
            file=StagedFile("unused", -1, FileIdentity(1, 1)),
            sha256=sha256,
            allocated_bytes=size,
        )


class ProductionContractTest(unittest.TestCase):
    def test_keeps_required_labels_and_exact_sizes(self) -> None:
        self.assertEqual(
            (
                ("fixture-256", 268_435_456),
                ("fixture-1024", 1_073_741_824),
            ),
            FIXTURE_SPECS,
        )

    def test_reserves_free_space_headroom(self) -> None:
        self.assertEqual(64 * 1024 * 1024, FREE_SPACE_HEADROOM_BYTES)
        specs = [FixtureSpec(label, size) for label, size in FIXTURE_SPECS]
        self.assertEqual(
            268_435_456 + 1_073_741_824 + FREE_SPACE_HEADROOM_BYTES,
            _required_free_space(specs),
        )


@unittest.skipUnless(
    shutil.which("ffmpeg") and shutil.which("ffprobe"),
    "ffmpeg and ffprobe are required",
)
class GeneratorIntegrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def test_published_fixture_matches_manifest_hash_and_ffprobe_input(self) -> None:
        output = self.root / "generated"
        results = self._generate_small(output)
        fixture = output / "fixture-small.mp4"
        manifest_path = output / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual(256 * 1024, fixture.stat().st_size)
        self.assertEqual(0o600, stat.S_IMODE(fixture.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(manifest_path.stat().st_mode))
        self.assertEqual(results[0].sha256, hashlib.sha256(fixture.read_bytes()).hexdigest())
        self.assertEqual(results[0].sha256, manifest["fixtures"][0]["sha256"])

        output_descriptor = _open_directory(output)
        fixture_descriptor = os.open(
            "fixture-small.mp4",
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=output_descriptor,
        )
        try:
            probe = _probe_video_descriptor(fixture_descriptor, "ffprobe")
            self.assertEqual(["video"], probe.stream_types)
        finally:
            os.close(fixture_descriptor)
            os.close(output_descriptor)

        self.assertEqual([], list(output.glob(".t093-*")))

    def test_base_video_is_reproducible_probeable_and_video_only(self) -> None:
        first = _generate_base_video("ffmpeg")
        second = _generate_base_video("ffmpeg")
        self.assertEqual(first, second)

        with tempfile.TemporaryFile(dir="/private/tmp") as base:
            base.write(first)
            base.flush()
            probe = _probe_video_descriptor(base.fileno(), "ffprobe")

        self.assertEqual(["video"], probe.stream_types)

    def test_fsync_failure_cleans_staging_without_publishing(self) -> None:
        output = self.root / "fsync-failure"

        with (
            patch("generate_t093_fixtures.FIXTURE_SPECS", (("fixture-small", 256 * 1024),)),
            patch("generate_t093_fixtures.os.fsync", side_effect=OSError("fsync failed")),
            self.assertRaisesRegex(OSError, "fsync failed"),
        ):
            generate_fixtures(output)

        self.assertEqual([], list(output.iterdir()))

    def test_publish_collision_racer_survives_cleanup(self) -> None:
        output = self.root / "publish-race"
        real_publish = _publish_file

        def lose_fixture_publish(
            staging_descriptor,
            staged_file,
            output_descriptor,
            final_name,
        ):
            if final_name == "fixture-small.mp4":
                descriptor = os.open(
                    final_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=output_descriptor,
                )
                os.write(descriptor, b"racer")
                os.close(descriptor)
                raise FileExistsError(final_name)
            return real_publish(
                staging_descriptor,
                staged_file,
                output_descriptor,
                final_name,
            )

        with (
            patch("generate_t093_fixtures._publish_file", side_effect=lose_fixture_publish),
            patch("generate_t093_fixtures.FIXTURE_SPECS", (("fixture-small", 256 * 1024),)),
            self.assertRaises(FileExistsError),
        ):
            generate_fixtures(output)

        self.assertEqual(b"racer", (output / "fixture-small.mp4").read_bytes())
        self.assertFalse((output / "manifest.json").exists())
        self.assertEqual([], list(output.glob(".t093-*")))

    def test_manifest_publish_collision_preserves_racer_and_published_fixture(self) -> None:
        output = self.root / "manifest-race"
        real_publish = _publish_file

        def lose_manifest_publish(
            staging_descriptor,
            staged_file,
            output_descriptor,
            final_name,
        ):
            if final_name == "manifest.json":
                descriptor = os.open(
                    final_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=output_descriptor,
                )
                os.write(descriptor, b"manifest-racer")
                os.close(descriptor)
                raise FileExistsError(final_name)
            return real_publish(
                staging_descriptor,
                staged_file,
                output_descriptor,
                final_name,
            )

        with (
            patch("generate_t093_fixtures._publish_file", side_effect=lose_manifest_publish),
            patch("generate_t093_fixtures.FIXTURE_SPECS", (("fixture-small", 256 * 1024),)),
            self.assertRaises(FileExistsError),
        ):
            generate_fixtures(output)

        self.assertEqual(b"manifest-racer", (output / "manifest.json").read_bytes())
        self.assertEqual(256 * 1024, (output / "fixture-small.mp4").stat().st_size)
        self.assertEqual([], list(output.glob(".t093-*")))

    def test_directory_retarget_writes_only_to_pinned_directory(self) -> None:
        output = self.root / "output"
        pinned = self.root / "pinned"
        redirected = self.root / "redirected"
        redirected.mkdir()
        real_create_staging = _create_staging_directory

        def retarget_after_directory_open(output_descriptor):
            output.rename(pinned)
            output.symlink_to(redirected, target_is_directory=True)
            return real_create_staging(output_descriptor)

        with (
            patch(
                "generate_t093_fixtures._create_staging_directory",
                side_effect=retarget_after_directory_open,
            ),
            patch("generate_t093_fixtures.FIXTURE_SPECS", (("fixture-small", 256 * 1024),)),
        ):
            generate_fixtures(output)

        self.assertEqual(256 * 1024, (pinned / "fixture-small.mp4").stat().st_size)
        self.assertTrue((pinned / "manifest.json").is_file())
        self.assertEqual([], list(redirected.iterdir()))
        self.assertEqual([], list(pinned.glob(".t093-*")))

    def test_refuses_existing_final_without_overwrite(self) -> None:
        output = prepare_output_directory(self.root / "existing")
        fixture = output / "fixture-small.mp4"
        fixture.write_bytes(b"existing")

        with (
            patch("generate_t093_fixtures.FIXTURE_SPECS", (("fixture-small", 256 * 1024),)),
            self.assertRaises(FileExistsError),
        ):
            generate_fixtures(output)

        self.assertEqual(b"existing", fixture.read_bytes())

    def test_refuses_existing_manifest_without_overwrite(self) -> None:
        output = prepare_output_directory(self.root / "existing-manifest")
        manifest = output / "manifest.json"
        manifest.write_bytes(b"existing-manifest")

        with (
            patch("generate_t093_fixtures.FIXTURE_SPECS", (("fixture-small", 256 * 1024),)),
            self.assertRaises(FileExistsError),
        ):
            generate_fixtures(output)

        self.assertEqual(b"existing-manifest", manifest.read_bytes())

    def test_refuses_final_symlink_without_touching_target(self) -> None:
        output = prepare_output_directory(self.root / "existing-symlink")
        target = self.root / "symlink-target"
        target.write_bytes(b"target")
        fixture = output / "fixture-small.mp4"
        fixture.symlink_to(target)

        with (
            patch("generate_t093_fixtures.FIXTURE_SPECS", (("fixture-small", 256 * 1024),)),
            self.assertRaises(FileExistsError),
        ):
            generate_fixtures(output)

        self.assertTrue(fixture.is_symlink())
        self.assertEqual(b"target", target.read_bytes())

    @staticmethod
    def _generate_small(output: Path):
        with patch(
            "generate_t093_fixtures.FIXTURE_SPECS",
            (("fixture-small", 256 * 1024),),
        ):
            return generate_fixtures(output)


if __name__ == "__main__":
    unittest.main()
