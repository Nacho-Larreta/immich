from __future__ import annotations

from typing import Any

from artifact_integrity import ArtifactVerifier
from capture_evidence import evaluate_capture
from evaluation_result import GateResult
from manifest_template import DEVICE_SLOTS, T091_CONDITIONS
from sanitized_exports import load_trace_export
from strict_evidence import (
    EvidenceValidationError,
    require_bool,
    require_enum,
    require_exact_keys,
    require_int,
    require_list,
    require_nullable_number,
    require_object,
)
from trace_reducers import TraceReducerRegistry


T091_THRESHOLD_SECONDS = 1.5


def evaluate_t091(
    raw: Any,
    verifier: ArtifactVerifier,
    reducers: TraceReducerRegistry,
    result: GateResult,
) -> None:
    gate = require_object(raw, "t091")
    require_exact_keys(gate, {"samples"}, "t091")
    samples = require_list(gate["samples"], "t091.samples")
    expected_keys = {
        (device, condition, run)
        for device in DEVICE_SLOTS
        for condition in T091_CONDITIONS
        for run in range(11)
    }
    observed_keys: set[tuple[str, str, int]] = set()
    measured_durations: dict[tuple[str, str], list[float]] = {
        (device, condition): []
        for device in DEVICE_SLOTS
        for condition in T091_CONDITIONS
    }

    for index, raw_sample in enumerate(samples):
        location = f"t091.samples[{index}]"
        sample = require_object(raw_sample, location)
        require_exact_keys(
            sample,
            {
                "device",
                "condition",
                "run",
                "warmup",
                "processStartSeconds",
                "timelineInteractiveSeconds",
                "capture",
                "metricsExport",
            },
            location,
        )
        device = require_enum(sample["device"], set(DEVICE_SLOTS), f"{location}.device")
        condition = require_enum(
            sample["condition"], set(T091_CONDITIONS), f"{location}.condition"
        )
        run = require_int(sample["run"], f"{location}.run", minimum=0, maximum=10)
        warmup = require_bool(sample["warmup"], f"{location}.warmup")
        if warmup != (run == 0):
            raise EvidenceValidationError("invalid_warmup_marker", location)
        key = (device, condition, run)
        if key in observed_keys:
            raise EvidenceValidationError("duplicate_t091_sample", location)
        observed_keys.add(key)

        role = f"T091-{device}-{condition.lower()}-r{run:02d}"
        if warmup:
            role += "-warmup"
        capture = evaluate_capture(sample["capture"], role, verifier, result)
        if capture is None:
            continue
        metrics = load_trace_export(
            verifier,
            sample["metricsExport"],
            role=f"{role}-metrics",
            kind="t091Launch",
            trace_sha256=capture.trace_sha256,
            reducers=reducers,
        )
        require_exact_keys(
            metrics,
            {"processStartSeconds", "timelineInteractiveSeconds", "timelineInteractiveCount"},
            f"{location}.metricsExport",
        )
        process_start = require_nullable_number(
            metrics["processStartSeconds"], f"{location}.metrics.processStartSeconds"
        )
        interactive = require_nullable_number(
            metrics["timelineInteractiveSeconds"],
            f"{location}.metrics.timelineInteractiveSeconds",
        )
        timeline_count = require_int(
            metrics["timelineInteractiveCount"],
            f"{location}.metrics.timelineInteractiveCount",
            minimum=0,
        )
        claimed_process_start = require_nullable_number(
            sample["processStartSeconds"], f"{location}.processStartSeconds"
        )
        claimed_interactive = require_nullable_number(
            sample["timelineInteractiveSeconds"],
            f"{location}.timelineInteractiveSeconds",
        )
        if claimed_process_start != process_start or claimed_interactive != interactive:
            raise EvidenceValidationError("launch_claim_export_mismatch", location)
        if capture.status == "freeze":
            if timeline_count != 0:
                raise EvidenceValidationError("freeze_export_has_timeline_marker", location)
            continue
        if timeline_count != 1:
            result.fail("timeline_interactive_marker_missing_or_duplicated")
            continue
        if process_start is None or interactive is None:
            raise EvidenceValidationError("missing_launch_timestamp", location)
        if process_start < 0 or interactive <= process_start:
            raise EvidenceValidationError("invalid_launch_timestamp", location)
        if not warmup:
            measured_durations[(device, condition)].append(interactive - process_start)

    if observed_keys != expected_keys:
        raise EvidenceValidationError("incomplete_t091_matrix", "t091.samples")

    cells: dict[str, Any] = {}
    for device in DEVICE_SLOTS:
        for condition in T091_CONDITIONS:
            durations = measured_durations[(device, condition)]
            key = f"{device}.{condition}"
            if len(durations) != 10:
                cells[key] = {"sampleCount": len(durations), "p95Seconds": None}
                continue
            p95 = max(durations)
            cells[key] = {"sampleCount": 10, "p95Seconds": round(p95, 6)}
            if condition in {"airplane", "blackHole"} and p95 > T091_THRESHOLD_SECONDS:
                result.fail("cold_launch_p95_exceeded")
    result.metrics["cells"] = cells
