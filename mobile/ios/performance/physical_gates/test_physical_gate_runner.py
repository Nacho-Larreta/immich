import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from physical_gate_runner import USAGE_EXIT_CODE, main


class PhysicalGateRunnerCliTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)

    def test_creates_private_template_outside_git_without_overwrite(self) -> None:
        output = self.root / "evidence" / "evidence-manifest.json"

        status, response = self.run_cli("create-template", "--output", str(output))

        self.assertEqual(0, status)
        self.assertEqual("CREATED", response["status"])
        self.assertEqual(2, response["schemaVersion"])
        self.assertEqual(2, json.loads(output.read_text())["schemaVersion"])
        self.assertEqual(0o600, output.stat().st_mode & 0o777)

        status, response = self.run_cli("create-template", "--output", str(output))
        self.assertEqual(2, status)
        self.assertEqual("INVALID", response["status"])

    def test_incomplete_template_evaluates_invalid_with_json_report(self) -> None:
        evidence = self.root / "evidence"
        manifest = evidence / "evidence-manifest.json"
        report = evidence / "report.json"
        self.run_cli("create-template", "--output", str(manifest))

        status, response = self.run_cli(
            "evaluate",
            "--manifest",
            str(manifest),
            "--evidence-root",
            str(evidence),
            "--fixture-root",
            str(self.root / "fixtures"),
            "--report",
            str(report),
        )

        self.assertEqual(2, status)
        self.assertEqual("INVALID", response["status"])
        self.assertEqual(response, json.loads(report.read_text()))

    def test_digests_trace_without_printing_a_path(self) -> None:
        evidence = self.root / "evidence"
        trace = evidence / "T091-D1-airplane-r00-warmup.trace"
        trace.mkdir(parents=True)
        evidence.chmod(0o700)
        (trace / "payload").write_bytes(b"trace")

        status, response = self.run_cli(
            "digest-artifact",
            "--evidence-root",
            str(evidence),
            "--role",
            "T091-D1-airplane-r00-warmup",
            "--format",
            "trace",
        )

        self.assertEqual(0, status)
        self.assertEqual("T091-D1-airplane-r00-warmup", response["role"])
        self.assertNotIn(str(evidence), json.dumps(response))

    def test_usage_error_has_separate_exit_code(self) -> None:
        status, response = self.run_cli("unknown-command")

        self.assertEqual(USAGE_EXIT_CODE, status)
        self.assertEqual("USAGE_ERROR", response["status"])

    @staticmethod
    def run_cli(*arguments: str):
        output = io.StringIO()
        with redirect_stdout(output):
            status = main(arguments)
        return status, json.loads(output.getvalue())


if __name__ == "__main__":
    unittest.main()
