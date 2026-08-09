import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import artifact_integrity
from artifact_integrity import (
    ArtifactVerifier,
    digest_artifact,
    write_private_json_exclusive,
)
from strict_evidence import EvidenceValidationError


class ArtifactIntegrityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def test_hashes_trace_bundle_deterministically(self) -> None:
        trace = self.root / "T091-D1-airplane-r00-warmup.trace"
        (trace / "nested").mkdir(parents=True)
        (trace / "first").write_bytes(b"first")
        (trace / "nested" / "second").write_bytes(b"second")

        first = digest_artifact(trace, "trace", "test")
        second = digest_artifact(trace, "trace", "test")

        self.assertEqual(first, second)
        self.assertEqual(11, first.byte_count)

    def test_rejects_symlink_inside_trace_bundle(self) -> None:
        trace = self.root / "T091-D1-airplane-r00-warmup.trace"
        trace.mkdir()
        target = self.root / "target"
        target.write_bytes(b"target")
        (trace / "linked").symlink_to(target)

        with self.assertRaisesRegex(EvidenceValidationError, "trace_symlink_forbidden"):
            digest_artifact(trace, "trace", "test")

    def test_rejects_trace_file_mutated_during_digest(self) -> None:
        trace = self.root / "T091-D1-airplane-r00-warmup.trace"
        trace.mkdir()
        payload = trace / "payload"
        payload.write_bytes(b"original")
        original_digest = artifact_integrity._digest_open_file

        def mutate_after_digest(descriptor: int, location: str):
            digest = original_digest(descriptor, location)
            payload.write_bytes(b"mutated-content")
            return digest

        with patch(
            "artifact_integrity._digest_open_file",
            side_effect=mutate_after_digest,
        ):
            with self.assertRaisesRegex(
                EvidenceValidationError,
                "trace_changed_while_hashing",
            ):
                digest_artifact(trace, "trace", "test")

    def test_verifier_recalculates_hash_and_byte_count(self) -> None:
        trace = self.root / "T091-D1-airplane-r00-warmup.trace"
        trace.mkdir()
        (trace / "payload").write_bytes(b"payload")
        digest = digest_artifact(trace, "trace", "test")
        record = {
            "role": "T091-D1-airplane-r00-warmup",
            "format": "trace",
            "sha256": digest.sha256,
            "byteCount": digest.byte_count,
        }

        verifier = ArtifactVerifier(self.root)
        self.assertEqual(
            digest,
            verifier.verify(
                record,
                expected_role="T091-D1-airplane-r00-warmup",
                expected_format="trace",
            ),
        )

        (trace / "payload").write_bytes(b"changed")
        with self.assertRaisesRegex(EvidenceValidationError, "artifact_integrity_mismatch"):
            ArtifactVerifier(self.root).verify(
                record,
                expected_role="T091-D1-airplane-r00-warmup",
                expected_format="trace",
            )

    def test_private_json_writer_refuses_overwrite(self) -> None:
        path = self.root / "report.json"
        write_private_json_exclusive(path, {"status": "PASS"})

        self.assertEqual(0o600, os.stat(path).st_mode & 0o777)
        with self.assertRaisesRegex(EvidenceValidationError, "output_not_created"):
            write_private_json_exclusive(path, {"status": "FAIL"})

    def test_private_json_writer_does_not_repermission_existing_parent(self) -> None:
        shared = self.root / "shared"
        shared.mkdir(mode=0o755)

        with self.assertRaisesRegex(EvidenceValidationError, "directory_not_private"):
            write_private_json_exclusive(shared / "report.json", {"status": "PASS"})

        self.assertEqual(0o755, shared.stat().st_mode & 0o777)


if __name__ == "__main__":
    unittest.main()
