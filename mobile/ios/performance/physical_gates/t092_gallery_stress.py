from __future__ import annotations

import json
from typing import Any

from artifact_integrity import ArtifactVerifier
from capture_evidence import evaluate_capture
from evaluation_result import GateResult
from manifest_template import (
    DEVICE_SLOTS,
    T092_BACKGROUND_TRAVERSALS,
    T092_CONTROL_TRAVERSALS,
    T092_ICLOUD_REQUESTS,
)
from sanitized_exports import load_trace_export
from strict_evidence import (
    EvidenceValidationError,
    require_bool,
    require_enum,
    require_exact_keys,
    require_int,
    require_list,
    require_number,
    require_object,
    require_string,
)
from trace_reducers import TraceReducerRegistry


MIB = 1024 * 1024
RESIDENT_GROWTH_LIMIT_BYTES = 64 * MIB


def evaluate_t092(
    raw: Any,
    subject_device: str,
    verifier: ArtifactVerifier,
    reducers: TraceReducerRegistry,
    result: GateResult,
) -> None:
    gate = require_object(raw, "t092")
    require_exact_keys(gate, {"device", "blackHoleRun", "controls"}, "t092")
    device = require_enum(gate["device"], set(DEVICE_SLOTS), "t092.device")
    if device != subject_device:
        raise EvidenceValidationError("t092_not_on_subject_device", "t092.device")
    _evaluate_black_hole(gate["blackHoleRun"], device, verifier, reducers, result)

    controls = require_object(gate["controls"], "t092.controls")
    require_exact_keys(controls, {"online", "airplane", "iCloudOnly"}, "t092.controls")
    _evaluate_traversal_control(
        controls["online"], device, "online", verifier, reducers, result
    )
    _evaluate_traversal_control(
        controls["airplane"], device, "airplane", verifier, reducers, result
    )
    _evaluate_icloud_control(controls["iCloudOnly"], device, verifier, reducers, result)


def _evaluate_black_hole(
    raw: Any,
    device: str,
    verifier: ArtifactVerifier,
    reducers: TraceReducerRegistry,
    result: GateResult,
) -> None:
    location = "t092.blackHoleRun"
    run = require_object(raw, location)
    require_exact_keys(
        run,
        {
            "continuous",
            "traversalsCompleted",
            "freezeOrCrash",
            "backgroundResumes",
            "baselineStabilizationSeconds",
            "finalStabilizationSeconds",
            "baselineResidentBytes",
            "finalResidentBytes",
            "baselineOpenTemporaries",
            "finalOpenTemporaries",
            "finalActiveRequests",
            "maxConcurrentPermits",
            "capture",
            "metricsExport",
        },
        location,
    )
    role = f"T092-{device}-blackhole-100"
    capture = evaluate_capture(run["capture"], role, verifier, result)
    if capture is None:
        return
    metrics = load_trace_export(
        verifier,
        run["metricsExport"],
        role=f"{role}-metrics",
        kind="t092BlackHole",
        trace_sha256=capture.trace_sha256,
        reducers=reducers,
    )
    metric_keys = set(run) - {"capture", "metricsExport"}
    require_exact_keys(metrics, metric_keys, f"{location}.metrics")
    _require_same_claims(metrics, {key: run[key] for key in metric_keys}, location)
    if require_bool(metrics["freezeOrCrash"], f"{location}.freezeOrCrash"):
        result.fail("freeze_or_crash")
        return

    if not require_bool(metrics["continuous"], f"{location}.continuous"):
        raise EvidenceValidationError("t092_not_continuous", location)
    if require_int(metrics["traversalsCompleted"], f"{location}.traversalsCompleted") != 100:
        raise EvidenceValidationError("t092_requires_exactly_100_traversals", location)
    _evaluate_background_resumes(metrics["backgroundResumes"])
    baseline_stabilization = require_number(
        metrics["baselineStabilizationSeconds"],
        f"{location}.baselineStabilizationSeconds",
    )
    final_stabilization = require_number(
        metrics["finalStabilizationSeconds"],
        f"{location}.finalStabilizationSeconds",
    )
    if baseline_stabilization < 30 or final_stabilization < 30:
        raise EvidenceValidationError("insufficient_memory_stabilization", location)

    baseline_resident = require_int(
        metrics["baselineResidentBytes"], f"{location}.baselineResidentBytes", minimum=1
    )
    final_resident = require_int(
        metrics["finalResidentBytes"], f"{location}.finalResidentBytes", minimum=1
    )
    if final_resident > baseline_resident + RESIDENT_GROWTH_LIMIT_BYTES:
        result.fail("resident_growth_exceeded")
    baseline_temporary = require_int(
        metrics["baselineOpenTemporaries"],
        f"{location}.baselineOpenTemporaries",
        minimum=0,
    )
    final_temporary = require_int(
        metrics["finalOpenTemporaries"],
        f"{location}.finalOpenTemporaries",
        minimum=0,
    )
    if final_temporary != baseline_temporary:
        result.fail("temporary_intervals_not_at_baseline")
    _require_zero_requests(metrics["finalActiveRequests"], f"{location}.finalActiveRequests", result)
    _evaluate_permit_limits(metrics["maxConcurrentPermits"], location, result)
    result.metrics["blackHole"] = {
        "traversals": 100,
        "residentGrowthBytes": final_resident - baseline_resident,
    }


def _evaluate_background_resumes(raw: Any) -> None:
    entries = require_list(raw, "t092.blackHoleRun.backgroundResumes")
    if len(entries) != len(T092_BACKGROUND_TRAVERSALS):
        raise EvidenceValidationError("incomplete_background_resume_matrix", "t092")
    observed: set[int] = set()
    for index, raw_entry in enumerate(entries):
        location = f"t092.blackHoleRun.backgroundResumes[{index}]"
        entry = require_object(raw_entry, location)
        require_exact_keys(entry, {"traversal", "durationSeconds"}, location)
        traversal = require_int(entry["traversal"], f"{location}.traversal")
        if traversal in observed:
            raise EvidenceValidationError("duplicate_background_resume", location)
        observed.add(traversal)
        if require_number(entry["durationSeconds"], f"{location}.durationSeconds") < 5:
            raise EvidenceValidationError("background_resume_too_short", location)
    if observed != set(T092_BACKGROUND_TRAVERSALS):
        raise EvidenceValidationError("incomplete_background_resume_matrix", "t092")


def _evaluate_traversal_control(
    raw: Any,
    device: str,
    condition: str,
    verifier: ArtifactVerifier,
    reducers: TraceReducerRegistry,
    result: GateResult,
) -> None:
    location = f"t092.controls.{condition}"
    control = require_object(raw, location)
    require_exact_keys(
        control,
        {"traversalsCompleted", "freezeOrCrash", "capture", "metricsExport"},
        location,
    )
    role = f"T092-{device}-{condition}-control"
    capture = evaluate_capture(control["capture"], role, verifier, result)
    if capture is None:
        return
    metrics = load_trace_export(
        verifier,
        control["metricsExport"],
        role=f"{role}-metrics",
        kind="t092TraversalControl",
        trace_sha256=capture.trace_sha256,
        reducers=reducers,
    )
    require_exact_keys(metrics, {"traversalsCompleted", "freezeOrCrash"}, f"{location}.metrics")
    _require_same_claims(
        metrics,
        {"traversalsCompleted": control["traversalsCompleted"], "freezeOrCrash": control["freezeOrCrash"]},
        location,
    )
    if require_bool(metrics["freezeOrCrash"], f"{location}.freezeOrCrash"):
        result.fail("freeze_or_crash")
        return
    if (
        require_int(metrics["traversalsCompleted"], f"{location}.traversalsCompleted")
        != T092_CONTROL_TRAVERSALS
    ):
        raise EvidenceValidationError("invalid_t092_control_count", location)


def _evaluate_icloud_control(
    raw: Any,
    device: str,
    verifier: ArtifactVerifier,
    reducers: TraceReducerRegistry,
    result: GateResult,
) -> None:
    location = "t092.controls.iCloudOnly"
    control = require_object(raw, location)
    require_exact_keys(
        control,
        {"residencyOracle", "requests", "freezeOrCrash", "capture", "metricsExport"},
        location,
    )
    if (
        require_string(control["residencyOracle"], f"{location}.residencyOracle")
        != "photosCloudBadgeAndLocalOnlyTerminal"
    ):
        raise EvidenceValidationError("invalid_icloud_residency_oracle", location)
    role = f"T092-{device}-icloudonly-control"
    capture = evaluate_capture(control["capture"], role, verifier, result)
    if capture is None:
        return
    metrics = load_trace_export(
        verifier,
        control["metricsExport"],
        role=f"{role}-metrics",
        kind="t092ICloudOnly",
        trace_sha256=capture.trace_sha256,
        reducers=reducers,
    )
    metric_keys = {"residencyOracle", "requests", "freezeOrCrash"}
    require_exact_keys(metrics, metric_keys, f"{location}.metrics")
    _require_same_claims(metrics, {key: control[key] for key in metric_keys}, location)
    if require_bool(metrics["freezeOrCrash"], f"{location}.freezeOrCrash"):
        result.fail("freeze_or_crash")
        return
    requests = require_list(metrics["requests"], f"{location}.requests")
    if len(requests) != T092_ICLOUD_REQUESTS:
        raise EvidenceValidationError("invalid_icloud_control_count", location)
    durations: list[float] = []
    for index, raw_request in enumerate(requests):
        request_location = f"{location}.requests[{index}]"
        request = require_object(raw_request, request_location)
        require_exact_keys(
            request,
            {
                "durationSeconds",
                "terminalOutcome",
                "networkBytes",
                "knownLocalFollowUpSeconds",
            },
            request_location,
        )
        duration = require_number(
            request["durationSeconds"], f"{request_location}.durationSeconds", minimum=0
        )
        durations.append(duration)
        if duration > 1:
            result.fail("icloud_local_only_latency_exceeded")
        if (
            require_string(request["terminalOutcome"], f"{request_location}.terminalOutcome")
            != "iCloudUnavailable"
        ):
            result.fail("icloud_local_only_wrong_terminal")
        if require_int(request["networkBytes"], f"{request_location}.networkBytes", minimum=0) != 0:
            result.fail("icloud_local_only_used_network")
        if (
            require_number(
                request["knownLocalFollowUpSeconds"],
                f"{request_location}.knownLocalFollowUpSeconds",
                minimum=0,
            )
            > 1
        ):
            result.fail("icloud_request_blocked_known_local_asset")
    result.metrics["iCloudOnly"] = {"requestCount": len(durations), "maxSeconds": max(durations)}


def _require_same_claims(source: Any, claims: Any, location: str) -> None:
    if json.dumps(source, sort_keys=True) != json.dumps(claims, sort_keys=True):
        raise EvidenceValidationError("claim_export_mismatch", location)


def _require_zero_requests(raw: Any, location: str, result: GateResult) -> None:
    requests = require_object(raw, location)
    expected = {
        "localThumbnail",
        "localOriginal",
        "remoteThumbnail",
        "remoteOriginal",
        "localOriginalExport",
        "remoteOriginalExport",
    }
    require_exact_keys(requests, expected, location)
    for key in expected:
        if require_int(requests[key], f"{location}.{key}", minimum=0) != 0:
            result.fail("active_requests_not_zero")


def _evaluate_permit_limits(raw: Any, location: str, result: GateResult) -> None:
    permits = require_object(raw, f"{location}.maxConcurrentPermits")
    limits = {"localThumbnail": 4, "localOriginal": 2, "originalExport": 2}
    require_exact_keys(permits, limits, f"{location}.maxConcurrentPermits")
    for key, limit in limits.items():
        if require_int(permits[key], f"{location}.maxConcurrentPermits.{key}", minimum=0) > limit:
            result.fail("permit_concurrency_exceeded")
