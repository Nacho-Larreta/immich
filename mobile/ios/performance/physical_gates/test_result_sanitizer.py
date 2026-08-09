from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from result_sanitizer import sanitize_t093_xctest_output, sanitize_t094_flutter_machine
from strict_evidence import EvidenceValidationError
from t093_original_share import LOCAL_CANCELLATION_TESTS
from t094_reconnect_smoke import REQUIRED_TEST_SUITES


REVISION = "a" * 40


class ResultSanitizerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def test_t093_keeps_only_allowlisted_passing_test_names(self) -> None:
        lines = [
            f"Test Case '-[RunnerTests.LocalOriginalExporterTests {name}]' passed"
            for name in sorted(LOCAL_CANCELLATION_TESTS)
        ]
        lines.append("secret token and /Users/private/path")
        raw = self._private_file("xctest.log", "\n".join(lines).encode())

        summary = sanitize_t093_xctest_output(raw, REVISION, 0)

        serialized = json.dumps(summary)
        self.assertEqual(sorted(LOCAL_CANCELLATION_TESTS), summary["payload"]["passedTests"])
        self.assertNotIn("secret token", serialized)
        self.assertNotIn("/Users/private/path", serialized)

    def test_t094_keeps_only_allowlisted_suite_counts(self) -> None:
        events = []
        for test_id, suite in enumerate(sorted(REQUIRED_TEST_SUITES), start=1):
            events.extend(
                (
                    {"type": "testStart", "test": {"id": test_id, "url": f"file:///private/{suite}", "name": "PII"}},
                    {"type": "testDone", "testID": test_id, "result": "success", "hidden": "secret"},
                )
            )
        events.append({"type": "done", "success": True})
        raw = self._private_file(
            "flutter-machine.jsonl",
            ("\n".join(json.dumps(event) for event in events) + "\n").encode(),
        )

        summary = sanitize_t094_flutter_machine(raw, REVISION, 0)

        serialized = json.dumps(summary)
        self.assertEqual(set(REQUIRED_TEST_SUITES), set(summary["payload"]["suites"]))
        self.assertNotIn("PII", serialized)
        self.assertNotIn("secret", serialized)

    def test_rejects_fifo_symlink_and_oversize_raw_output(self) -> None:
        regular = self._private_file("regular.log", b"{}\n")
        symlink = self.root / "symlink.log"
        symlink.symlink_to(regular)
        fifo = self.root / "fifo.log"
        os.mkfifo(fifo, 0o600)
        oversize = self._private_file("oversize.log", b"")
        os.truncate(oversize, 16 * 1024 * 1024 + 1)

        for path in (symlink, fifo, oversize):
            with self.subTest(path=path.name):
                with self.assertRaises(EvidenceValidationError):
                    sanitize_t093_xctest_output(path, REVISION, 0)

    def _private_file(self, name: str, payload: bytes) -> Path:
        path = self.root / name
        path.write_bytes(payload)
        path.chmod(0o600)
        return path


if __name__ == "__main__":
    unittest.main()
