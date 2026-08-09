from __future__ import annotations

import json
import stat
from pathlib import Path
from typing import Any

from artifact_integrity import (
    ArtifactVerifier,
    digest_regular_file,
    require_private_external_directory,
)
from capture_evidence import evaluate_capture
from evaluation_result import GateResult
from manifest_template import DEVICE_SLOTS, T093_CASES
from sanitized_exports import load_summary_export, load_trace_export
from strict_evidence import (
    EvidenceValidationError,
    load_strict_json_document,
    require_enum,
    require_exact_keys,
    require_int,
    require_list,
    require_number,
    require_object,
    require_sha256,
    require_source_revision,
    require_string,
)
from trace_reducers import TraceReducerRegistry


MIB = 1024 * 1024
RESIDENT_PEAK_LIMIT_BYTES = 96 * MIB
LOCAL_CANCELLATION_TESTS = {
    "testCancellationBeforeNativeIdAttachCancelsAndDeletesPartExactlyOnce",
    "testCancellationBetweenDestinationCreationAndWriterAttachCleansBeforeCompletion",
    "testCancellationDuringBlockedAppendWaitsForWriterThenCompletesBarrier",
    "testAtMostTwoExportsRunAndQueuedCancellationNeverStartsPhotoKit",
    "testGlobalPoolLimitsMixedLocalAndRemoteExportsAndQueuedCancelStartsNothing",
}


def evaluate_t093(
    raw: Any,
    limiting_device: str,
    source_revision: str,
    fixture_root: Path,
    verifier: ArtifactVerifier,
    reducers: TraceReducerRegistry,
    result: GateResult,
) -> None:
    gate = require_object(raw, "t093")
    require_exact_keys(
        gate,
        {
            "device",
            "fixtureGeneratorContract",
            "fixtureManifestSha256",
            "fixtureManifestByteCount",
            "localCancellationAutomatedEvidence",
            "cases",
        },
        "t093",
    )
    device = require_enum(gate["device"], set(DEVICE_SLOTS), "t093.device")
    if device != limiting_device:
        raise EvidenceValidationError("t093_not_on_limiting_device", "t093.device")
    if (
        require_string(gate["fixtureGeneratorContract"], "t093.fixtureGeneratorContract")
        != "manifestPublishedAfterFfprobe"
    ):
        raise EvidenceValidationError("invalid_fixture_generator_contract", "t093")
    fixture_hashes = verify_fixture_set(gate, fixture_root)
    _evaluate_local_cancellation_tests(
        gate["localCancellationAutomatedEvidence"],
        source_revision,
        verifier,
        result,
    )

    raw_cases = require_list(gate["cases"], "t093.cases")
    expected_keys = set(T093_CASES)
    observed_keys: set[tuple[str, str, str]] = set()
    success_deltas: dict[tuple[str, str], int] = {}
    for index, raw_case in enumerate(raw_cases):
        location = f"t093.cases[{index}]"
        case = require_object(raw_case, location)
        require_exact_keys(
            case,
            {
                "adapter",
                "operation",
                "fixture",
                "result",
                "residentBaselineBytes",
                "residentPeakBytes",
                "baselineOpenTemporaries",
                "finalOpenTemporaries",
                "finalActiveRequests",
                "finalActivePermits",
                "capture",
                "metricsExport",
                "cancellation",
            },
            location,
        )
        adapter = require_enum(
            case["adapter"], {"localPhotoKit", "remoteURLSession"}, f"{location}.adapter"
        )
        operation = require_enum(
            case["operation"],
            {"success256", "success1024", "cancel1024"},
            f"{location}.operation",
        )
        fixture = require_enum(
            case["fixture"], {"fixture-256", "fixture-1024"}, f"{location}.fixture"
        )
        key = (adapter, operation, fixture)
        if key in observed_keys:
            raise EvidenceValidationError("duplicate_t093_case", location)
        observed_keys.add(key)
        if key not in expected_keys:
            raise EvidenceValidationError("wrong_t093_fixture_mapping", location)

        adapter_slug = "local" if adapter == "localPhotoKit" else "remote"
        role = f"T093-{device}-{adapter_slug}-{operation.lower()}"
        capture = evaluate_capture(case["capture"], role, verifier, result)
        if capture is None:
            continue
        metrics = load_trace_export(
            verifier,
            case["metricsExport"],
            role=f"{role}-metrics",
            kind="t093OriginalShare",
            trace_sha256=capture.trace_sha256,
            reducers=reducers,
        )
        metric_keys = {
            "result",
            "residentBaselineBytes",
            "residentPeakBytes",
            "baselineOpenTemporaries",
            "finalOpenTemporaries",
            "finalActiveRequests",
            "finalActivePermits",
            "cancellation",
        }
        require_exact_keys(metrics, metric_keys, f"{location}.metrics")
        claimed_metrics = {key: case[key] for key in metric_keys if key != "cancellation"}
        claimed_metrics["cancellation"] = _trace_cancellation_claim(case["cancellation"])
        _require_same_claims(metrics, claimed_metrics, location)

        expected_result = "cancelled" if operation == "cancel1024" else "success"
        observed_result = require_enum(
            metrics["result"], {"success", "cancelled", "failed"}, f"{location}.result"
        )
        if observed_result != expected_result:
            result.fail("original_export_wrong_result")
        baseline = require_int(
            metrics["residentBaselineBytes"],
            f"{location}.residentBaselineBytes",
            minimum=1,
        )
        peak = require_int(
            metrics["residentPeakBytes"], f"{location}.residentPeakBytes", minimum=1
        )
        if peak < baseline:
            raise EvidenceValidationError("resident_peak_below_baseline", location)
        if peak > RESIDENT_PEAK_LIMIT_BYTES:
            result.fail("resident_peak_exceeded")
        if operation.startswith("success"):
            success_deltas[(adapter, operation)] = peak - baseline

        baseline_temp = require_int(
            metrics["baselineOpenTemporaries"],
            f"{location}.baselineOpenTemporaries",
            minimum=0,
        )
        final_temp = require_int(
            metrics["finalOpenTemporaries"],
            f"{location}.finalOpenTemporaries",
            minimum=0,
        )
        if final_temp != baseline_temp:
            result.fail("temporary_intervals_not_at_baseline")
        _evaluate_zero_intervals(metrics, location, result)
        _evaluate_cancellation(
            case["cancellation"],
            metrics["cancellation"],
            adapter,
            operation,
            role,
            capture.trace_sha256,
            verifier,
            reducers,
            result,
        )

    if observed_keys != expected_keys:
        raise EvidenceValidationError("incomplete_t093_matrix", "t093.cases")
    for adapter in ("localPhotoKit", "remoteURLSession"):
        delta_256 = success_deltas[(adapter, "success256")]
        delta_1024 = success_deltas[(adapter, "success1024")]
        if 2 * delta_1024 > 3 * delta_256:
            result.fail("resident_delta_ratio_exceeded")
        result.metrics[adapter] = {
            "fixture256Sha256": fixture_hashes["fixture-256"],
            "delta256Bytes": delta_256,
            "delta1024Bytes": delta_1024,
        }


def verify_fixture_set(gate: dict[str, Any], fixture_root: Path) -> dict[str, str]:
    root = require_private_external_directory(fixture_root, "fixture_root")
    manifest_path = root / "manifest.json"
    document = load_strict_json_document(
        manifest_path,
        root=root,
        location="t093.fixtureManifest",
    )
    if document.sha256 != require_sha256(
        gate["fixtureManifestSha256"], "t093.fixtureManifestSha256"
    ) or document.byte_count != require_int(
        gate["fixtureManifestByteCount"],
        "t093.fixtureManifestByteCount",
        minimum=1,
    ):
        raise EvidenceValidationError("fixture_manifest_integrity_mismatch", "t093")

    fixture_manifest = document.value
    require_exact_keys(fixture_manifest, {"schemaVersion", "fixtures"}, "fixtureManifest")
    if require_int(fixture_manifest["schemaVersion"], "fixtureManifest.schemaVersion") != 1:
        raise EvidenceValidationError("unsupported_fixture_manifest", "fixtureManifest")
    fixtures = require_list(fixture_manifest["fixtures"], "fixtureManifest.fixtures")
    expected = {
        "fixture-256": ("fixture-256.mp4", 268_435_456),
        "fixture-1024": ("fixture-1024.mp4", 1_073_741_824),
    }
    hashes: dict[str, str] = {}
    for index, raw_fixture in enumerate(fixtures):
        location = f"fixtureManifest.fixtures[{index}]"
        fixture = require_object(raw_fixture, location)
        require_exact_keys(
            fixture,
            {"label", "file", "sizeBytes", "allocatedBytes", "sha256"},
            location,
        )
        label = require_enum(fixture["label"], set(expected), f"{location}.label")
        if label in hashes:
            raise EvidenceValidationError("duplicate_fixture", location)
        expected_file, expected_size = expected[label]
        if require_string(fixture["file"], f"{location}.file") != expected_file:
            raise EvidenceValidationError("invalid_fixture_filename", location)
        size = require_int(fixture["sizeBytes"], f"{location}.sizeBytes", minimum=1)
        allocated = require_int(
            fixture["allocatedBytes"], f"{location}.allocatedBytes", minimum=1
        )
        expected_hash = require_sha256(fixture["sha256"], f"{location}.sha256")
        if size != expected_size or allocated < size:
            raise EvidenceValidationError("fixture_size_or_allocation_invalid", location)

        fixture_path = root / expected_file
        try:
            status = fixture_path.lstat()
        except OSError as error:
            raise EvidenceValidationError("fixture_missing", location) from error
        if not stat.S_ISREG(status.st_mode) or stat.S_ISLNK(status.st_mode):
            raise EvidenceValidationError("fixture_must_be_regular_file", location)
        actual_allocated = status.st_blocks * 512
        actual_digest = digest_regular_file(fixture_path, location)
        if (
            actual_digest.sha256 != expected_hash
            or actual_digest.byte_count != expected_size
            or actual_allocated != allocated
            or actual_allocated < expected_size
        ):
            raise EvidenceValidationError("fixture_integrity_mismatch", location)
        hashes[label] = expected_hash
    if set(hashes) != set(expected):
        raise EvidenceValidationError("incomplete_fixture_set", "fixtureManifest")
    return hashes


def _evaluate_local_cancellation_tests(
    raw: Any,
    source_revision: str,
    verifier: ArtifactVerifier,
    result: GateResult,
) -> None:
    location = "t093.localCancellationAutomatedEvidence"
    evidence = require_object(raw, location)
    require_exact_keys(
        evidence,
        {"commandId", "sourceRevision", "exitCode", "artifact"},
        location,
    )
    command_id = require_string(evidence["commandId"], f"{location}.commandId")
    if command_id != "t093LocalCancellationXCTestV1":
        raise EvidenceValidationError("unknown_t093_test_command", location)
    if require_source_revision(evidence["sourceRevision"], f"{location}.sourceRevision") != source_revision:
        raise EvidenceValidationError("t093_revision_mismatch", location)
    exit_code = require_int(evidence["exitCode"], f"{location}.exitCode")
    summary = load_summary_export(
        verifier,
        evidence["artifact"],
        role="T093-local-cancellation-tests",
        kind="t093LocalCancellationTests",
    )
    require_exact_keys(
        summary,
        {"commandId", "sourceRevision", "exitCode", "passedTests"},
        f"{location}.summary",
    )
    if (
        require_string(summary["commandId"], f"{location}.summary.commandId") != command_id
        or require_source_revision(
            summary["sourceRevision"], f"{location}.summary.sourceRevision"
        )
        != source_revision
        or require_int(summary["exitCode"], f"{location}.summary.exitCode") != exit_code
    ):
        raise EvidenceValidationError("t093_test_summary_mismatch", location)
    raw_passed_tests = require_list(
        summary["passedTests"], f"{location}.summary.passedTests"
    )
    passed_tests = [
        require_string(value, f"{location}.summary.passedTests[{index}]")
        for index, value in enumerate(raw_passed_tests)
    ]
    if len(passed_tests) != len(set(passed_tests)) or set(passed_tests) != LOCAL_CANCELLATION_TESTS:
        raise EvidenceValidationError("incomplete_t093_cancellation_tests", location)
    if exit_code != 0:
        result.fail("t093_local_cancellation_tests_failed")


def _trace_cancellation_claim(raw: Any) -> dict[str, Any] | None:
    if raw is None:
        return None
    cancellation = require_object(raw, "t093.cancellation")
    return {
        key: cancellation[key]
        for key in ("fraction", "stabilizationSeconds", "requestIntervalClosedSeconds")
    }


def _require_same_claims(source: Any, claims: Any, location: str) -> None:
    if json.dumps(source, sort_keys=True) != json.dumps(claims, sort_keys=True):
        raise EvidenceValidationError("claim_export_mismatch", location)


def _evaluate_zero_intervals(
    case: dict[str, Any],
    location: str,
    result: GateResult,
) -> None:
    requests = require_object(case["finalActiveRequests"], f"{location}.finalActiveRequests")
    require_exact_keys(
        requests,
        {"localOriginalExport", "remoteOriginalExport"},
        f"{location}.finalActiveRequests",
    )
    if any(
        require_int(value, f"{location}.finalActiveRequests.{name}", minimum=0) != 0
        for name, value in requests.items()
    ):
        result.fail("active_requests_not_zero")
    permits = require_object(case["finalActivePermits"], f"{location}.finalActivePermits")
    require_exact_keys(permits, {"originalExport"}, f"{location}.finalActivePermits")
    if (
        require_int(
            permits["originalExport"],
            f"{location}.finalActivePermits.originalExport",
            minimum=0,
        )
        != 0
    ):
        result.fail("active_permits_not_zero")


def _evaluate_cancellation(
    raw: Any,
    trace_metrics: Any,
    adapter: str,
    operation: str,
    role: str,
    trace_sha256: str,
    verifier: ArtifactVerifier,
    reducers: TraceReducerRegistry,
    result: GateResult,
) -> None:
    if operation != "cancel1024":
        if raw is not None or trace_metrics is not None:
            raise EvidenceValidationError("unexpected_cancellation_evidence", role)
        return
    location = f"{role}.cancellation"
    cancellation = require_object(raw, location)
    require_exact_keys(
        cancellation,
        {
            "fraction",
            "stabilizationSeconds",
            "requestIntervalClosedSeconds",
            "contentLengthBytes",
            "bytesAtCancellation",
            "bytesAfterStabilization",
            "networkConnectionsExport",
        },
        location,
    )
    metrics = require_object(trace_metrics, f"{location}.traceMetrics")
    require_exact_keys(
        metrics,
        {"fraction", "stabilizationSeconds", "requestIntervalClosedSeconds"},
        f"{location}.traceMetrics",
    )
    fraction = require_number(metrics["fraction"], f"{location}.fraction")
    if not 0.25 <= fraction <= 0.50:
        raise EvidenceValidationError("cancellation_outside_required_window", location)
    if require_number(
        metrics["stabilizationSeconds"], f"{location}.stabilizationSeconds"
    ) < 2:
        raise EvidenceValidationError("abort_stabilization_too_short", location)
    if require_number(
        metrics["requestIntervalClosedSeconds"],
        f"{location}.requestIntervalClosedSeconds",
        minimum=0,
    ) > 1:
        result.fail("producer_did_not_abort_promptly")
    if adapter == "localPhotoKit":
        for key in (
            "contentLengthBytes",
            "bytesAtCancellation",
            "bytesAfterStabilization",
            "networkConnectionsExport",
        ):
            if cancellation[key] is not None:
                raise EvidenceValidationError("unexpected_local_network_evidence", location)
        return

    network = load_trace_export(
        verifier,
        cancellation["networkConnectionsExport"],
        role=f"{role}-network",
        kind="t093RemoteNetworkCancellation",
        trace_sha256=trace_sha256,
        reducers=reducers,
    )
    require_exact_keys(
        network,
        {"contentLengthBytes", "bytesAtCancellation", "bytesAfterStabilization"},
        f"{location}.network",
    )
    network_claim = {
        key: cancellation[key]
        for key in ("contentLengthBytes", "bytesAtCancellation", "bytesAfterStabilization")
    }
    _require_same_claims(network, network_claim, location)
    content_length = require_int(
        network["contentLengthBytes"],
        f"{location}.contentLengthBytes",
        minimum=1,
    )
    if content_length != 1_073_741_824:
        raise EvidenceValidationError("remote_content_length_mismatch", location)
    bytes_at_cancel = require_int(
        network["bytesAtCancellation"],
        f"{location}.bytesAtCancellation",
        minimum=0,
    )
    bytes_after = require_int(
        network["bytesAfterStabilization"],
        f"{location}.bytesAfterStabilization",
        minimum=0,
    )
    if bytes_after != bytes_at_cancel or bytes_after >= content_length:
        result.fail("remote_network_producer_not_aborted")
