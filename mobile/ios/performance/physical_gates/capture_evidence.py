from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from artifact_integrity import ArtifactVerifier
from evaluation_result import GateResult
from strict_evidence import (
    EvidenceValidationError,
    require_enum,
    require_exact_keys,
    require_list,
    require_object,
)


INVALID_CAPTURE_REASONS = {
    "device_disconnect",
    "instruments_error",
    "trace_corrupt",
}


@dataclass(frozen=True)
class CaptureOutcome:
    status: str
    trace_sha256: str


def evaluate_capture(
    raw: Any,
    role: str,
    verifier: ArtifactVerifier,
    result: GateResult,
) -> CaptureOutcome | None:
    capture = require_object(raw, f"capture.{role}")
    require_exact_keys(capture, {"attempts"}, f"capture.{role}")
    attempts = require_list(capture["attempts"], f"capture.{role}.attempts")
    if len(attempts) not in (1, 2):
        raise EvidenceValidationError("invalid_capture_attempt_count", f"capture.{role}")

    statuses: list[str] = []
    trace_hashes: list[str] = []
    for index, raw_attempt in enumerate(attempts):
        location = f"capture.{role}.attempts[{index}]"
        attempt = require_object(raw_attempt, location)
        require_exact_keys(attempt, {"status", "invalidReason", "artifact"}, location)
        status = require_enum(
            attempt["status"], {"valid", "freeze", "invalid"}, f"{location}.status"
        )
        statuses.append(status)
        attempt_role = role if index == 0 else f"{role}-retry1"
        trace_digest = verifier.verify(
            attempt["artifact"],
            expected_role=attempt_role,
            expected_format="trace",
        )
        trace_hashes.append(trace_digest.sha256)
        invalid_reason = attempt["invalidReason"]

        if status == "invalid":
            require_enum(invalid_reason, INVALID_CAPTURE_REASONS, f"{location}.invalidReason")
            continue
        if invalid_reason is not None:
            raise EvidenceValidationError("unexpected_invalid_reason", location)
        if status == "freeze":
            result.fail("freeze_or_crash")

    if len(statuses) == 2 and statuses[0] != "invalid":
        raise EvidenceValidationError("retry_without_invalid_capture", f"capture.{role}")
    final_status = statuses[-1]
    if final_status == "invalid":
        result.invalid("capture_invalid_after_single_retry")
        return None
    return CaptureOutcome(final_status, trace_hashes[-1])
