from __future__ import annotations

from typing import Any

from artifact_integrity import ArtifactVerifier
from capture_evidence import evaluate_capture
from evaluation_result import GateResult
from manifest_template import (
    DEVICE_SLOTS,
    T094_PRIMARY_SCENARIOS,
    T094_SECONDARY_SCENARIOS,
    _camel_to_kebab,
)
from sanitized_exports import load_summary_export
from strict_evidence import (
    EvidenceValidationError,
    require_bool,
    require_enum,
    require_exact_keys,
    require_int,
    require_list,
    require_object,
    require_source_revision,
    require_string,
)


REQUIRED_TEST_SUITES = {
    "test/domain/services/server_reachability_coordinator_test.dart",
    "test/infrastructure/adapters/reconciliation/server_reconciliation_adapter_test.dart",
    "test/providers/session_work_provider_test.dart",
    "test/routing/auth_guard_test.dart",
}


def evaluate_t094(
    raw: Any,
    source_revision: str,
    verifier: ArtifactVerifier,
    result: GateResult,
) -> None:
    gate = require_object(raw, "t094")
    require_exact_keys(
        gate,
        {
            "automatedEvidence",
            "primaryDevice",
            "secondaryDevice",
            "primaryScenarios",
            "secondaryScenarios",
        },
        "t094",
    )
    automated = require_object(gate["automatedEvidence"], "t094.automatedEvidence")
    require_exact_keys(
        automated,
        {"commandId", "sourceRevision", "exitCode", "artifact"},
        "t094.automatedEvidence",
    )
    if (
        require_string(automated["commandId"], "t094.automatedEvidence.commandId")
        != "t094ScopedFlutterTestsV1"
    ):
        raise EvidenceValidationError("unknown_t094_test_command", "t094.automatedEvidence")
    if (
        require_source_revision(
            automated["sourceRevision"], "t094.automatedEvidence.sourceRevision"
        )
        != source_revision
    ):
        raise EvidenceValidationError("t094_revision_mismatch", "t094.automatedEvidence")
    exit_code = require_int(automated["exitCode"], "t094.automatedEvidence.exitCode")
    summary = load_summary_export(
        verifier,
        automated["artifact"],
        role="T094-scoped-flutter-tests",
        kind="t094ScopedFlutterTests",
    )
    require_exact_keys(
        summary,
        {"commandId", "sourceRevision", "exitCode", "suites"},
        "t094.automatedEvidence.summary",
    )
    if (
        require_string(summary["commandId"], "t094.summary.commandId")
        != automated["commandId"]
        or require_source_revision(summary["sourceRevision"], "t094.summary.sourceRevision")
        != source_revision
        or require_int(summary["exitCode"], "t094.summary.exitCode") != exit_code
    ):
        raise EvidenceValidationError("t094_test_summary_mismatch", "t094.automatedEvidence")
    _evaluate_suite_summary(summary["suites"], result)
    if exit_code != 0:
        result.fail("t094_scoped_tests_failed")

    primary = require_enum(gate["primaryDevice"], set(DEVICE_SLOTS), "t094.primaryDevice")
    secondary = require_enum(
        gate["secondaryDevice"], set(DEVICE_SLOTS), "t094.secondaryDevice"
    )
    if primary == secondary:
        raise EvidenceValidationError("t094_requires_two_devices", "t094")
    _evaluate_scenarios(
        gate["primaryScenarios"],
        primary,
        T094_PRIMARY_SCENARIOS,
        verifier,
        result,
        "primary",
    )
    _evaluate_scenarios(
        gate["secondaryScenarios"],
        secondary,
        T094_SECONDARY_SCENARIOS,
        verifier,
        result,
        "secondary",
    )


def _evaluate_scenarios(
    raw: Any,
    device: str,
    expected_names: tuple[str, ...],
    verifier: ArtifactVerifier,
    result: GateResult,
    lane: str,
) -> None:
    scenarios = require_list(raw, f"t094.{lane}Scenarios")
    observed: set[str] = set()
    for index, raw_scenario in enumerate(scenarios):
        location = f"t094.{lane}Scenarios[{index}]"
        scenario = require_object(raw_scenario, location)
        require_exact_keys(
            scenario,
            {
                "name",
                "freezeOrCrash",
                "timelineUsableAfter",
                "staleEndpointPublished",
                "oldSessionSideEffectObserved",
                "capture",
            },
            location,
        )
        name = require_enum(scenario["name"], set(expected_names), f"{location}.name")
        if name in observed:
            raise EvidenceValidationError("duplicate_t094_scenario", location)
        observed.add(name)
        if require_bool(scenario["freezeOrCrash"], f"{location}.freezeOrCrash"):
            result.fail("freeze_or_crash")
        if not require_bool(scenario["timelineUsableAfter"], f"{location}.timelineUsableAfter"):
            result.fail("timeline_not_usable_after_transition")
        if require_bool(
            scenario["staleEndpointPublished"], f"{location}.staleEndpointPublished"
        ):
            result.fail("stale_endpoint_observed")
        if require_bool(
            scenario["oldSessionSideEffectObserved"],
            f"{location}.oldSessionSideEffectObserved",
        ):
            result.fail("old_session_side_effect_observed")
        role = f"T094-{device}-{_camel_to_kebab(name)}"
        evaluate_capture(scenario["capture"], role, verifier, result)
    if observed != set(expected_names):
        raise EvidenceValidationError("incomplete_t094_scenario_matrix", f"t094.{lane}")


def _evaluate_suite_summary(raw: Any, result: GateResult) -> None:
    suites = require_object(raw, "t094.summary.suites")
    require_exact_keys(suites, REQUIRED_TEST_SUITES, "t094.summary.suites")
    for path, raw_counts in suites.items():
        counts = require_object(raw_counts, f"t094.summary.suites.{path}")
        require_exact_keys(counts, {"passed", "failed", "skipped"}, f"t094.summary.suites.{path}")
        passed = require_int(counts["passed"], f"t094.summary.suites.{path}.passed", minimum=0)
        failed = require_int(counts["failed"], f"t094.summary.suites.{path}.failed", minimum=0)
        skipped = require_int(
            counts["skipped"],
            f"t094.summary.suites.{path}.skipped",
            minimum=0,
        )
        if passed == 0 or failed != 0 or skipped != 0:
            result.fail("t094_scoped_tests_failed")
