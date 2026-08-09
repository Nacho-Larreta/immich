from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any

from artifact_integrity import ARTIFACT_FORMAT_SUFFIXES, digest_artifact
from evidence_schema import SCHEMA_VERSION
from manifest_template import create_manifest_template
from t093_original_share import LOCAL_CANCELLATION_TESTS
from t094_reconnect_smoke import REQUIRED_TEST_SUITES
from trace_reducers import TRACE_REDUCERS, TraceReducerRegistry


MIB = 1024 * 1024
TEST_TRACE_REDUCERS = TraceReducerRegistry(frozenset(TRACE_REDUCERS.values()))


@dataclass
class PreparedEvidence:
    manifest: dict[str, Any]
    evidence_root: Path
    fixture_root: Path

    @classmethod
    def create(cls, root: Path) -> "PreparedEvidence":
        evidence_root = root / "evidence"
        fixture_root = root / "fixtures"
        evidence_root.mkdir(mode=0o700)
        fixture_root.mkdir(mode=0o700)
        manifest = _completed_manifest()
        _materialize_artifacts(manifest, evidence_root, manifest)
        return cls(manifest, evidence_root, fixture_root)

    def create_artifact(self, record: dict[str, Any]) -> None:
        _materialize_artifact(record, self.evidence_root, self.manifest)

    def refresh_json_artifacts(self) -> None:
        for record in _artifact_records(self.manifest):
            if record["format"] != "json":
                continue
            path = self.evidence_root / f'{record["role"]}.json'
            path.unlink()
            _materialize_artifact(record, self.evidence_root, self.manifest)

    def replace_json_artifact(self, role: str, document: dict[str, Any]) -> None:
        record = _find_artifact(self.manifest, role)
        path = self.evidence_root / f"{role}.json"
        path.write_text(json.dumps(document, sort_keys=True) + "\n", encoding="utf-8")
        path.chmod(0o600)
        digest = digest_artifact(path, "json", f"test.{role}")
        record.update({"sha256": digest.sha256, "byteCount": digest.byte_count})


def _completed_manifest() -> dict[str, Any]:
    manifest = create_manifest_template()
    manifest["build"] = {
        "marketingVersion": "2.7.5",
        "buildNumber": "3047",
        "bundleIdentifier": "app.immich.private",
        "sourceRevision": "a" * 40,
    }
    manifest["devices"] = {
        "D1": {
            "model": "iPhone 16 Pro",
            "iosVersion": "26.5",
            "physicalMemoryBytes": 4_000 * MIB,
            "baselineResidentBytes": 100 * MIB,
        },
    }
    manifest["blackHole"].update(
        {
            "endpointUnchanged": True,
            "nwPathStatus": "satisfied",
            "icloudReachable": True,
            "nasConfigurationChanged": False,
        }
    )

    for sample in manifest["t091"]["samples"]:
        sample["processStartSeconds"] = 1.0
        sample["timelineInteractiveSeconds"] = 2.0
        _complete_capture(sample["capture"])

    t092 = manifest["t092"]
    t092["device"] = "D1"
    black_hole = t092["blackHoleRun"]
    black_hole.update(
        {
            "continuous": True,
            "traversalsCompleted": 100,
            "freezeOrCrash": False,
            "baselineStabilizationSeconds": 30,
            "finalStabilizationSeconds": 30,
            "baselineResidentBytes": 100 * MIB,
            "finalResidentBytes": 120 * MIB,
            "baselineOpenTemporaries": 0,
            "finalOpenTemporaries": 0,
        }
    )
    for resume in black_hole["backgroundResumes"]:
        resume["durationSeconds"] = 5
    for name in black_hole["finalActiveRequests"]:
        black_hole["finalActiveRequests"][name] = 0
    black_hole["maxConcurrentPermits"].update(
        {"localThumbnail": 4, "localOriginal": 2, "originalExport": 2}
    )
    _complete_capture(black_hole["capture"])
    for condition in ("online", "airplane"):
        control = t092["controls"][condition]
        control["traversalsCompleted"] = 5
        control["freezeOrCrash"] = False
        _complete_capture(control["capture"])
    icloud = t092["controls"]["iCloudOnly"]
    icloud["freezeOrCrash"] = False
    for request in icloud["requests"]:
        request.update(
            {
                "durationSeconds": 0.5,
                "terminalOutcome": "iCloudUnavailable",
                "networkBytes": 0,
                "knownLocalFollowUpSeconds": 0.5,
            }
        )
    _complete_capture(icloud["capture"])

    t093 = manifest["t093"]
    t093["device"] = "D1"
    t093["localCancellationAutomatedEvidence"].update(
        {"sourceRevision": "a" * 40, "exitCode": 0}
    )
    for case in t093["cases"]:
        operation = case["operation"]
        case.update(
            {
                "result": "cancelled" if operation == "cancel1024" else "success",
                "residentBaselineBytes": 32 * MIB,
                "residentPeakBytes": (
                    64 * MIB if operation == "success256" else 80 * MIB
                ),
                "baselineOpenTemporaries": 0,
                "finalOpenTemporaries": 0,
            }
        )
        case["finalActiveRequests"].update(
            {"localOriginalExport": 0, "remoteOriginalExport": 0}
        )
        case["finalActivePermits"]["originalExport"] = 0
        _complete_capture(case["capture"])
        cancellation = case["cancellation"]
        if cancellation is not None:
            cancellation.update(
                {
                    "fraction": 0.4,
                    "stabilizationSeconds": 2,
                    "requestIntervalClosedSeconds": 0.5,
                }
            )
            if case["adapter"] == "remoteURLSession":
                cancellation.update(
                    {
                        "contentLengthBytes": 1_073_741_824,
                        "bytesAtCancellation": 400_000_000,
                        "bytesAfterStabilization": 400_000_000,
                    }
                )

    t094 = manifest["t094"]
    t094["automatedEvidence"].update(
        {"sourceRevision": "a" * 40, "exitCode": 0}
    )
    t094["primaryDevice"] = "D1"
    for scenario in t094["primaryScenarios"]:
        scenario.update(
            {
                "freezeOrCrash": False,
                "timelineUsableAfter": True,
                "staleEndpointPublished": False,
                "oldSessionSideEffectObserved": False,
            }
        )
        _complete_capture(scenario["capture"])

    return manifest


def _complete_capture(capture: dict[str, Any]) -> None:
    capture["attempts"][0].update(
        {
            "status": "valid",
            "invalidReason": None,
        }
    )


def _materialize_artifacts(value: Any, evidence_root: Path, manifest: dict[str, Any]) -> None:
    if type(value) is dict:
        if _is_artifact_record(value):
            _materialize_artifact(value, evidence_root, manifest)
            return
        for child in value.values():
            _materialize_artifacts(child, evidence_root, manifest)
    elif type(value) is list:
        for child in value:
            _materialize_artifacts(child, evidence_root, manifest)


def _materialize_artifact(
    record: dict[str, Any],
    evidence_root: Path,
    manifest: dict[str, Any],
) -> None:
    role = record["role"]
    artifact_format = record["format"]
    path = evidence_root / f"{role}{ARTIFACT_FORMAT_SUFFIXES[artifact_format]}"
    payload = f"sanitized evidence for {role}\n".encode()
    if artifact_format == "trace":
        path.mkdir()
        (path / "payload.bin").write_bytes(payload)
    else:
        if artifact_format == "json":
            payload = (
                json.dumps(_json_export(role, manifest), sort_keys=True) + "\n"
            ).encode()
        path.write_bytes(payload)
        path.chmod(0o600)
    digest = digest_artifact(path, artifact_format, f"test.{role}")
    record["sha256"] = digest.sha256
    record["byteCount"] = digest.byte_count


def _json_export(role: str, manifest: dict[str, Any]) -> dict[str, Any]:
    if role.startswith("T091-"):
        trace_role = role.removesuffix("-metrics")
        sample = next(
            item
            for item in manifest["t091"]["samples"]
            if item["capture"]["attempts"][0]["artifact"]["role"] == trace_role
        )
        return _trace_export(
            "t091Launch",
            _capture_trace_sha(sample["capture"]),
            {
                "processStartSeconds": sample["processStartSeconds"],
                "timelineInteractiveSeconds": sample["timelineInteractiveSeconds"],
                "timelineInteractiveCount": (
                    0 if sample["capture"]["attempts"][-1]["status"] == "freeze" else 1
                ),
            },
        )
    if role == "T092-D1-blackhole-100-metrics":
        run = manifest["t092"]["blackHoleRun"]
        payload = {key: value for key, value in run.items() if key not in {"capture", "metricsExport"}}
        return _trace_export("t092BlackHole", _capture_trace_sha(run["capture"]), payload)
    if role in {"T092-D1-online-control-metrics", "T092-D1-airplane-control-metrics"}:
        condition = "online" if "-online-" in role else "airplane"
        control = manifest["t092"]["controls"][condition]
        payload = {
            "traversalsCompleted": control["traversalsCompleted"],
            "freezeOrCrash": control["freezeOrCrash"],
        }
        return _trace_export(
            "t092TraversalControl",
            _capture_trace_sha(control["capture"]),
            payload,
        )
    if role == "T092-D1-icloudonly-control-metrics":
        control = manifest["t092"]["controls"]["iCloudOnly"]
        payload = {key: control[key] for key in ("residencyOracle", "requests", "freezeOrCrash")}
        return _trace_export(
            "t092ICloudOnly",
            _capture_trace_sha(control["capture"]),
            payload,
        )
    if role == "T093-local-cancellation-tests":
        evidence = manifest["t093"]["localCancellationAutomatedEvidence"]
        return {
            "schemaVersion": SCHEMA_VERSION,
            "kind": "t093LocalCancellationTests",
            "payload": {
                "commandId": "t093LocalCancellationXCTestV1",
                "sourceRevision": evidence["sourceRevision"],
                "exitCode": evidence["exitCode"],
                "passedTests": sorted(LOCAL_CANCELLATION_TESTS),
            },
        }
    if role.startswith("T093-") and role.endswith("-metrics"):
        trace_role = role.removesuffix("-metrics")
        case = _t093_case_for_role(manifest, trace_role)
        cancellation = case["cancellation"]
        payload = {
            key: case[key]
            for key in (
                "result",
                "residentBaselineBytes",
                "residentPeakBytes",
                "baselineOpenTemporaries",
                "finalOpenTemporaries",
                "finalActiveRequests",
                "finalActivePermits",
            )
        }
        payload["cancellation"] = (
            None
            if cancellation is None
            else {
                key: cancellation[key]
                for key in ("fraction", "stabilizationSeconds", "requestIntervalClosedSeconds")
            }
        )
        return _trace_export(
            "t093OriginalShare",
            _capture_trace_sha(case["capture"]),
            payload,
        )
    if role.startswith("T093-") and role.endswith("-network"):
        trace_role = role.removesuffix("-network")
        cancellation = _t093_case_for_role(manifest, trace_role)["cancellation"]
        payload = {
            key: cancellation[key]
            for key in ("contentLengthBytes", "bytesAtCancellation", "bytesAfterStabilization")
        }
        return _trace_export(
            "t093RemoteNetworkCancellation",
            _capture_trace_sha(_t093_case_for_role(manifest, trace_role)["capture"]),
            payload,
        )
    if role == "T094-scoped-flutter-tests":
        evidence = manifest["t094"]["automatedEvidence"]
        return {
            "schemaVersion": SCHEMA_VERSION,
            "kind": "t094ScopedFlutterTests",
            "payload": {
                "commandId": "t094ScopedFlutterTestsV1",
                "sourceRevision": evidence["sourceRevision"],
                "exitCode": evidence["exitCode"],
                "suites": {
                    suite: {"passed": 1, "failed": 0, "skipped": 0}
                    for suite in REQUIRED_TEST_SUITES
                },
            },
        }
    raise AssertionError(f"No sanitized test export for {role}")


def _trace_export(kind: str, trace_sha256: str, payload: dict[str, Any]) -> dict[str, Any]:
    reducer_id, reducer_version = TRACE_REDUCERS[kind]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": kind,
        "reducerId": reducer_id,
        "reducerVersion": reducer_version,
        "traceSha256": trace_sha256,
        "payload": payload,
    }


def _capture_trace_sha(capture: dict[str, Any]) -> str:
    artifact = capture["attempts"][-1]["artifact"]
    if artifact["sha256"] is None:
        raise AssertionError(f'Trace {artifact["role"]} was not materialized first')
    return artifact["sha256"]


def _artifact_records(value: Any):
    if type(value) is dict:
        if _is_artifact_record(value):
            yield value
            return
        for child in value.values():
            yield from _artifact_records(child)
    elif type(value) is list:
        for child in value:
            yield from _artifact_records(child)


def _find_artifact(value: Any, role: str) -> dict[str, Any]:
    if type(value) is dict:
        if _is_artifact_record(value) and value["role"] == role:
            return value
        for child in value.values():
            try:
                return _find_artifact(child, role)
            except LookupError:
                pass
    elif type(value) is list:
        for child in value:
            try:
                return _find_artifact(child, role)
            except LookupError:
                pass
    raise LookupError(role)


def _is_artifact_record(value: dict[str, Any]) -> bool:
    artifact_keys = {"role", "format", "sha256", "byteCount"}
    return set(value) in (
        artifact_keys,
        artifact_keys | {"reducerId", "reducerVersion"},
    )


def _t093_case_for_role(manifest: dict[str, Any], role: str) -> dict[str, Any]:
    return next(
        case
        for case in manifest["t093"]["cases"]
        if case["capture"]["attempts"][0]["artifact"]["role"] == role
    )
