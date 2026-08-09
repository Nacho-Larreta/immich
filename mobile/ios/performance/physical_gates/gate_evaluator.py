from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from artifact_integrity import ArtifactVerifier
from evidence_schema import SCHEMA_VERSION
from evaluation_result import EvaluationReport, EvaluationStatus, GateResult
from manifest_template import DEVICE_SLOT, DEVICE_SLOTS
from strict_evidence import (
    EvidenceValidationError,
    require_bool,
    require_bundle_identifier,
    require_enum,
    require_exact_keys,
    require_int,
    require_object,
    require_source_revision,
    require_string,
    require_version,
)
from t091_cold_launch import evaluate_t091
from t092_gallery_stress import evaluate_t092
from t093_original_share import evaluate_t093
from t094_reconnect_smoke import evaluate_t094
from trace_reducers import TraceReducerRegistry


@dataclass(frozen=True)
class GlobalEvidence:
    source_revision: str
    subject_device: str


def evaluate_manifest(
    manifest: dict[str, Any],
    evidence_root: Path,
    fixture_root: Path,
    trace_reducers: TraceReducerRegistry | None = None,
) -> EvaluationReport:
    reducers = trace_reducers or TraceReducerRegistry()
    verifier = ArtifactVerifier(evidence_root)
    gates = {name: GateResult() for name in ("GLOBAL", "T091", "T092", "T093", "T094")}

    try:
        global_evidence = _evaluate_global(manifest)
    except EvidenceValidationError as error:
        gates["GLOBAL"].invalid(error.code)
        for name in ("T091", "T092", "T093", "T094"):
            gates[name].invalid("not_evaluated")
        return EvaluationReport(EvaluationStatus.INVALID, verifier.verified_count, gates)

    evaluators: tuple[tuple[str, Callable[[], None]], ...] = (
        (
            "T091",
            lambda: evaluate_t091(
                manifest["t091"], verifier, reducers, gates["T091"]
            ),
        ),
        (
            "T092",
            lambda: evaluate_t092(
                manifest["t092"],
                global_evidence.subject_device,
                verifier,
                reducers,
                gates["T092"],
            ),
        ),
        (
            "T093",
            lambda: evaluate_t093(
                manifest["t093"],
                global_evidence.subject_device,
                global_evidence.source_revision,
                fixture_root,
                verifier,
                reducers,
                gates["T093"],
            ),
        ),
        (
            "T094",
            lambda: evaluate_t094(
                manifest["t094"],
                global_evidence.source_revision,
                verifier,
                gates["T094"],
            ),
        ),
    )
    for name, evaluator in evaluators:
        try:
            evaluator()
        except EvidenceValidationError as error:
            gates[name].invalid(error.code)

    overall = max(result.status for result in gates.values())
    return EvaluationReport(overall, verifier.verified_count, gates)


def invalid_report(code: str) -> EvaluationReport:
    global_result = GateResult()
    global_result.invalid(code)
    gates = {name: GateResult() for name in ("GLOBAL", "T091", "T092", "T093", "T094")}
    gates["GLOBAL"] = global_result
    for name in ("T091", "T092", "T093", "T094"):
        gates[name].invalid("not_evaluated")
    return EvaluationReport(EvaluationStatus.INVALID, 0, gates)


def _evaluate_global(manifest: dict[str, Any]) -> GlobalEvidence:
    require_exact_keys(
        manifest,
        {
            "schemaVersion",
            "build",
            "devices",
            "blackHole",
            "t091",
            "t092",
            "t093",
            "t094",
        },
        "manifest",
    )
    if require_int(manifest["schemaVersion"], "schemaVersion") != SCHEMA_VERSION:
        raise EvidenceValidationError("unsupported_schema_version", "schemaVersion")

    build = require_object(manifest["build"], "build")
    require_exact_keys(
        build,
        {"marketingVersion", "buildNumber", "bundleIdentifier", "sourceRevision"},
        "build",
    )
    require_version(build["marketingVersion"], "build.marketingVersion")
    build_number = require_string(build["buildNumber"], "build.buildNumber")
    if not build_number.isdecimal():
        raise EvidenceValidationError("invalid_build_number", "build.buildNumber")
    require_bundle_identifier(build["bundleIdentifier"], "build.bundleIdentifier")
    source_revision = require_source_revision(build["sourceRevision"], "build.sourceRevision")

    devices = require_object(manifest["devices"], "devices")
    require_exact_keys(devices, DEVICE_SLOTS, "devices")
    for slot in DEVICE_SLOTS:
        _evaluate_device(devices[slot], f"devices.{slot}")
    _evaluate_black_hole_setup(manifest["blackHole"])
    return GlobalEvidence(source_revision, DEVICE_SLOT)


def _evaluate_device(raw: Any, location: str) -> None:
    device = require_object(raw, location)
    require_exact_keys(
        device,
        {
            "model",
            "iosVersion",
            "physicalMemoryBytes",
            "baselineResidentBytes",
        },
        location,
    )
    model = require_string(device["model"], f"{location}.model")
    if not model.startswith("iPhone") or len(model) > 40:
        raise EvidenceValidationError("invalid_device_model", f"{location}.model")
    require_version(device["iosVersion"], f"{location}.iosVersion")
    physical_memory = require_int(
        device["physicalMemoryBytes"],
        f"{location}.physicalMemoryBytes",
        minimum=1,
    )
    baseline_resident = require_int(
        device["baselineResidentBytes"],
        f"{location}.baselineResidentBytes",
        minimum=1,
    )
    if baseline_resident >= physical_memory:
        raise EvidenceValidationError("invalid_device_memory_baseline", location)


def _evaluate_black_hole_setup(raw: Any) -> None:
    black_hole = require_object(raw, "blackHole")
    require_exact_keys(
        black_hole,
        {
            "appliedAt",
            "action",
            "scope",
            "endpointUnchanged",
            "nwPathStatus",
            "icloudReachable",
            "nasConfigurationChanged",
        },
        "blackHole",
    )
    expected_values = {
        "appliedAt": "clientSpecificRouterAcl",
        "action": "drop",
        "scope": "nasIpAndPortOnly",
        "nwPathStatus": "satisfied",
    }
    for key, expected in expected_values.items():
        if require_string(black_hole[key], f"blackHole.{key}") != expected:
            raise EvidenceValidationError("invalid_black_hole_setup", f"blackHole.{key}")
    if not require_bool(black_hole["endpointUnchanged"], "blackHole.endpointUnchanged"):
        raise EvidenceValidationError("invalid_black_hole_setup", "blackHole.endpointUnchanged")
    if not require_bool(black_hole["icloudReachable"], "blackHole.icloudReachable"):
        raise EvidenceValidationError("invalid_black_hole_setup", "blackHole.icloudReachable")
    if require_bool(
        black_hole["nasConfigurationChanged"],
        "blackHole.nasConfigurationChanged",
    ):
        raise EvidenceValidationError("invalid_black_hole_setup", "blackHole.nasConfigurationChanged")
