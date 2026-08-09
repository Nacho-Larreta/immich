import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from artifact_integrity import digest_artifact
from evaluation_result import EvaluationStatus
from gate_evaluator import evaluate_manifest
from test_support import PreparedEvidence, TEST_TRACE_REDUCERS


FIXTURE_HASHES = {"fixture-256": "1" * 64, "fixture-1024": "2" * 64}


class PhysicalGateEvaluatorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary_directory.cleanup)
        self.prepared = PreparedEvidence.create(Path(self.temporary_directory.name))

    def evaluate(self, *, synchronize_exports: bool = True):
        if synchronize_exports:
            self.prepared.refresh_json_artifacts()
        with patch("t093_original_share.verify_fixture_set", return_value=FIXTURE_HASHES):
            return evaluate_manifest(
                self.prepared.manifest,
                self.prepared.evidence_root,
                self.prepared.fixture_root,
                TEST_TRACE_REDUCERS,
            )

    def evaluate_production(self):
        with patch("t093_original_share.verify_fixture_set", return_value=FIXTURE_HASHES):
            return evaluate_manifest(
                self.prepared.manifest,
                self.prepared.evidence_root,
                self.prepared.fixture_root,
            )

    def test_complete_manifest_passes_all_gates(self) -> None:
        report = self.evaluate()

        self.assertEqual(EvaluationStatus.PASS, report.status)
        self.assertTrue(all(gate.status == EvaluationStatus.PASS for gate in report.gates.values()))
        self.assertGreater(report.artifact_count, 80)
        self.assertEqual(1.0, report.gates["T091"].metrics["cells"]["D1.airplane"]["p95Seconds"])

    def test_hand_authored_trace_json_is_invalid_without_pinned_reducer(self) -> None:
        report = self.evaluate_production()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        for gate in ("T091", "T092", "T093"):
            self.assertFinding(report, gate, "trace_reducer_unavailable", "INVALID")

    def test_online_launch_is_a_control_without_threshold(self) -> None:
        sample = self._t091_sample("D1", "online", 10)
        sample["timelineInteractiveSeconds"] = 4.0

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.PASS, report.status)
        self.assertEqual(3.0, report.gates["T091"].metrics["cells"]["D1.online"]["p95Seconds"])

    def test_airplane_p95_uses_maximum_and_fails_over_threshold(self) -> None:
        sample = self._t091_sample("D2", "airplane", 7)
        sample["timelineInteractiveSeconds"] = 2.500001

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T091", "cold_launch_p95_exceeded", "FAIL")

    def test_freeze_without_marker_is_a_failure_not_invalid_capture(self) -> None:
        sample = self._t091_sample("D1", "blackHole", 4)
        sample["processStartSeconds"] = None
        sample["timelineInteractiveSeconds"] = None
        attempt = sample["capture"]["attempts"][0]
        attempt.update({"status": "freeze"})

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T091", "freeze_or_crash", "FAIL")

    def test_one_enumerated_acquisition_retry_can_recover(self) -> None:
        sample = self._t091_sample("D1", "airplane", 3)
        first = sample["capture"]["attempts"][0]
        first.update(
            {
                "status": "invalid",
                "invalidReason": "device_disconnect",
            }
        )
        retry = {
            "status": "valid",
            "invalidReason": None,
            "artifact": {
                "role": "T091-D1-airplane-r03-retry1",
                "format": "trace",
                "sha256": None,
                "byteCount": None,
            },
        }
        sample["capture"]["attempts"].append(retry)
        self.prepared.create_artifact(retry["artifact"])

        self.assertEqual(EvaluationStatus.PASS, self.evaluate().status)

    def test_slow_sample_cannot_be_relabeled_as_acquisition_invalid(self) -> None:
        attempt = self._t091_sample("D1", "airplane", 2)["capture"]["attempts"][0]
        attempt.update(
            {
                "status": "invalid",
                "invalidReason": "slow_sample",
            }
        )

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T091", "unsupported_enum_value", "INVALID")

    def test_rejects_99_or_101_black_hole_traversals(self) -> None:
        for traversal_count in (99, 101):
            with self.subTest(traversal_count=traversal_count):
                self.prepared.manifest["t092"]["blackHoleRun"]["traversalsCompleted"] = traversal_count
                report = self.evaluate()
                self.assertEqual(EvaluationStatus.INVALID, report.status)
                self.assertFinding(
                    report,
                    "T092",
                    "t092_requires_exactly_100_traversals",
                    "INVALID",
                )
                self.prepared.manifest["t092"]["blackHoleRun"]["traversalsCompleted"] = 100

    def test_t092_black_hole_freeze_is_fail_before_traversal_count(self) -> None:
        run = self.prepared.manifest["t092"]["blackHoleRun"]
        run["freezeOrCrash"] = True
        run["traversalsCompleted"] = 37

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T092", "freeze_or_crash", "FAIL")

    def test_t092_control_freeze_is_fail_before_control_count(self) -> None:
        control = self.prepared.manifest["t092"]["controls"]["online"]
        control["freezeOrCrash"] = True
        control["traversalsCompleted"] = 2

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T092", "freeze_or_crash", "FAIL")

    def test_t092_control_count_mismatch_without_freeze_is_invalid(self) -> None:
        control = self.prepared.manifest["t092"]["controls"]["online"]
        control["traversalsCompleted"] = 2

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T092", "invalid_t092_control_count", "INVALID")

    def test_rejects_missing_tenth_background_resume(self) -> None:
        self.prepared.manifest["t092"]["blackHoleRun"]["backgroundResumes"].pop()

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T092", "incomplete_background_resume_matrix", "INVALID")

    def test_wrong_limiting_device_is_invalid(self) -> None:
        self.prepared.manifest["limitingDevice"]["slot"] = "D2"

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "GLOBAL", "wrong_limiting_device", "INVALID")
        for gate in ("T091", "T092", "T093", "T094"):
            self.assertFinding(report, gate, "not_evaluated", "INVALID")

    def test_lower_physical_memory_wins_even_when_other_device_has_lower_margin(self) -> None:
        d2 = self.prepared.manifest["devices"]["D2"]
        d2["selectionBaselineResidentBytes"] = 2_500 * 1024 * 1024
        d2["measuredMemoryMarginBytes"] = 3_500 * 1024 * 1024

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.PASS, report.status)

    def test_global_schema_failure_marks_every_physical_gate_not_evaluated(self) -> None:
        self.prepared.manifest["schemaVersion"] = 2

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "GLOBAL", "unsupported_schema_version", "INVALID")
        for gate in ("T091", "T092", "T093", "T094"):
            self.assertFinding(report, gate, "not_evaluated", "INVALID")

    def test_t092_temporary_count_must_equal_not_merely_not_increase(self) -> None:
        run = self.prepared.manifest["t092"]["blackHoleRun"]
        run["baselineOpenTemporaries"] = 1
        run["finalOpenTemporaries"] = 0

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T092", "temporary_intervals_not_at_baseline", "FAIL")

    def test_t092_checks_each_concurrency_pool_separately(self) -> None:
        permits = self.prepared.manifest["t092"]["blackHoleRun"]["maxConcurrentPermits"]
        permits["originalExport"] = 3

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T092", "permit_concurrency_exceeded", "FAIL")

    def test_t092_icloud_oracle_requires_five_bounded_zero_network_samples(self) -> None:
        requests = self.prepared.manifest["t092"]["controls"]["iCloudOnly"]["requests"]
        requests[0]["durationSeconds"] = 1.01
        requests[1]["networkBytes"] = 1

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T092", "icloud_local_only_latency_exceeded", "FAIL")
        self.assertFinding(report, "T092", "icloud_local_only_used_network", "FAIL")

    def test_t093_ratio_uses_success_cases_per_adapter(self) -> None:
        remote_cancel = self._t093_case("remoteURLSession", "cancel1024")
        remote_cancel["residentPeakBytes"] = 95 * 1024 * 1024

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.PASS, report.status)

    def test_t093_fails_remote_cancel_when_bytes_continue_or_reach_content_length(self) -> None:
        cancellation = self._t093_case("remoteURLSession", "cancel1024")["cancellation"]
        cancellation["bytesAfterStabilization"] = cancellation["bytesAtCancellation"] + 1

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T093", "remote_network_producer_not_aborted", "FAIL")

    def test_t093_missing_network_connections_proof_is_invalid(self) -> None:
        cancellation = self._t093_case("remoteURLSession", "cancel1024")["cancellation"]
        cancellation["networkConnectionsExport"] = None

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T093", "expected_object", "INVALID")

    def test_t093_rejects_peak_below_baseline_instead_of_accepting_negative_delta(self) -> None:
        case = self._t093_case("localPhotoKit", "success256")
        case["residentPeakBytes"] = case["residentBaselineBytes"] - 1

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T093", "resident_peak_below_baseline", "INVALID")

    def test_t094_requires_green_automated_evidence(self) -> None:
        self.prepared.manifest["t094"]["automatedEvidence"]["exitCode"] = 1

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T094", "t094_scoped_tests_failed", "FAIL")

    def test_t094_skipped_scoped_test_is_a_failure(self) -> None:
        role = "T094-scoped-flutter-tests"
        path = self.prepared.evidence_root / f"{role}.json"
        summary = json.loads(path.read_text(encoding="utf-8"))
        first_suite = next(iter(summary["payload"]["suites"].values()))
        first_suite["skipped"] = 1
        self.prepared.replace_json_artifact(role, summary)

        report = self.evaluate(synchronize_exports=False)

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T094", "t094_scoped_tests_failed", "FAIL")

    def test_arbitrary_trace_reducer_identity_is_rejected(self) -> None:
        sample = self._t091_sample("D1", "airplane", 1)
        sample["metricsExport"]["reducerId"] = "arbitrary.reducer"

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T091", "unknown_trace_reducer", "INVALID")

    def test_t094_cannot_pass_with_physical_evidence_only(self) -> None:
        del self.prepared.manifest["t094"]["automatedEvidence"]

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T094", "unexpected_or_missing_keys", "INVALID")

    def test_non_t091_freeze_does_not_require_timeline_marker_evidence(self) -> None:
        scenario = self.prepared.manifest["t094"]["primaryScenarios"][0]
        scenario["capture"]["attempts"][0]["status"] = "freeze"

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.FAIL, report.status)
        self.assertFinding(report, "T094", "freeze_or_crash", "FAIL")
        self.assertFalse(any(finding["status"] == "INVALID" for finding in report.gates["T094"].findings))

    def test_rejects_claim_that_does_not_match_sanitized_trace_content(self) -> None:
        self._t091_sample("D1", "airplane", 1)["timelineInteractiveSeconds"] = 2.25

        report = self.evaluate(synchronize_exports=False)

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T091", "launch_claim_export_mismatch", "INVALID")

    def test_t093_requires_complete_native_cancellation_test_proof(self) -> None:
        role = "T093-local-cancellation-tests"
        path = self.prepared.evidence_root / f"{role}.json"
        summary = json.loads(path.read_text(encoding="utf-8"))
        summary["payload"]["passedTests"].pop()
        self.prepared.replace_json_artifact(role, summary)

        report = self.evaluate(synchronize_exports=False)

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T093", "incomplete_t093_cancellation_tests", "INVALID")

    def test_reused_trace_digest_is_invalid_even_with_distinct_roles(self) -> None:
        first = self._t091_sample("D1", "online", 1)["capture"]["attempts"][0]["artifact"]
        second = self._t091_sample("D1", "online", 2)["capture"]["attempts"][0]["artifact"]
        first_path = self.prepared.evidence_root / f"{first['role']}.trace" / "payload.bin"
        second_path = self.prepared.evidence_root / f"{second['role']}.trace" / "payload.bin"
        second_path.write_bytes(first_path.read_bytes())
        second_digest = digest_artifact(second_path.parent, "trace", "test")
        second.update({"sha256": second_digest.sha256, "byteCount": second_digest.byte_count})

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T091", "artifact_digest_reused", "INVALID")

    def test_boolean_is_not_accepted_as_numeric_evidence(self) -> None:
        self.prepared.manifest["t092"]["blackHoleRun"]["traversalsCompleted"] = True

        report = self.evaluate()

        self.assertEqual(EvaluationStatus.INVALID, report.status)
        self.assertFinding(report, "T092", "expected_integer", "INVALID")

    def _t091_sample(self, device: str, condition: str, run: int):
        return next(
            sample
            for sample in self.prepared.manifest["t091"]["samples"]
            if sample["device"] == device
            and sample["condition"] == condition
            and sample["run"] == run
        )

    def _t093_case(self, adapter: str, operation: str):
        return next(
            case
            for case in self.prepared.manifest["t093"]["cases"]
            if case["adapter"] == adapter and case["operation"] == operation
        )

    def assertFinding(self, report, gate: str, code: str, status: str) -> None:
        self.assertIn({"status": status, "code": code}, report.gates[gate].findings)


if __name__ == "__main__":
    unittest.main()
