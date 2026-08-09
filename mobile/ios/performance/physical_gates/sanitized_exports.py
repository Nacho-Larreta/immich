from __future__ import annotations

from typing import Any

from artifact_integrity import ArtifactVerifier
from strict_evidence import (
    EvidenceValidationError,
    require_exact_keys,
    require_int,
    require_object,
    require_sha256,
    require_string,
)
from trace_reducers import TraceReducerRegistry


def load_trace_export(
    verifier: ArtifactVerifier,
    raw_artifact: Any,
    *,
    role: str,
    kind: str,
    trace_sha256: str,
    reducers: TraceReducerRegistry,
) -> dict[str, Any]:
    reference = require_object(raw_artifact, role)
    artifact_keys = {"role", "format", "sha256", "byteCount"}
    require_exact_keys(
        reference,
        artifact_keys | {"reducerId", "reducerVersion"},
        role,
    )
    reducer_id = require_string(reference["reducerId"], f"{role}.reducerId")
    reducer_version = require_int(
        reference["reducerVersion"],
        f"{role}.reducerVersion",
        minimum=1,
    )
    reducers.require(kind, reducer_id, reducer_version)
    document = verifier.verify_json(
        {key: reference[key] for key in artifact_keys},
        expected_role=role,
    )
    export = document.value
    require_exact_keys(
        export,
        {
            "schemaVersion",
            "kind",
            "reducerId",
            "reducerVersion",
            "traceSha256",
            "payload",
        },
        role,
    )
    if require_int(export["schemaVersion"], f"{role}.schemaVersion") != 1:
        raise EvidenceValidationError("unsupported_export_schema", role)
    if require_string(export["kind"], f"{role}.kind") != kind:
        raise EvidenceValidationError("wrong_export_kind", role)
    if (
        require_string(export["reducerId"], f"{role}.reducerId") != reducer_id
        or require_int(export["reducerVersion"], f"{role}.reducerVersion")
        != reducer_version
    ):
        raise EvidenceValidationError("trace_reducer_identity_mismatch", role)
    if require_sha256(export["traceSha256"], f"{role}.traceSha256") != trace_sha256:
        raise EvidenceValidationError("export_trace_hash_mismatch", role)
    return require_object(export["payload"], f"{role}.payload")


def load_summary_export(
    verifier: ArtifactVerifier,
    raw_artifact: Any,
    *,
    role: str,
    kind: str,
) -> dict[str, Any]:
    document = verifier.verify_json(raw_artifact, expected_role=role)
    summary = document.value
    require_exact_keys(summary, {"schemaVersion", "kind", "payload"}, role)
    if require_int(summary["schemaVersion"], f"{role}.schemaVersion") != 1:
        raise EvidenceValidationError("unsupported_export_schema", role)
    if require_string(summary["kind"], f"{role}.kind") != kind:
        raise EvidenceValidationError("wrong_export_kind", role)
    return require_object(summary["payload"], f"{role}.payload")
