from __future__ import annotations

from typing import Any

from trace_reducers import TRACE_REDUCERS


DEVICE_SLOTS = ("D1", "D2")
T091_CONDITIONS = ("online", "airplane", "blackHole")
T092_CONTROL_TRAVERSALS = 5
T092_ICLOUD_REQUESTS = 5
T092_BACKGROUND_TRAVERSALS = tuple(range(10, 101, 10))
T093_CASES = (
    ("localPhotoKit", "success256", "fixture-256"),
    ("localPhotoKit", "success1024", "fixture-1024"),
    ("localPhotoKit", "cancel1024", "fixture-1024"),
    ("remoteURLSession", "success256", "fixture-256"),
    ("remoteURLSession", "success1024", "fixture-1024"),
    ("remoteURLSession", "cancel1024", "fixture-1024"),
)
T094_PRIMARY_SCENARIOS = (
    "blackHoleToOnlineDuringProbe",
    "backgroundResumeDuringSync",
    "logoutLoginDuringProbe",
    "logoutLoginDuringSync",
)
T094_SECONDARY_SCENARIOS = (
    "blackHoleToOnline",
    "backgroundResume",
    "logoutLogin",
)


def create_manifest_template() -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "build": {
            "marketingVersion": None,
            "buildNumber": None,
            "bundleIdentifier": None,
            "sourceRevision": None,
        },
        "devices": {
            slot: {
                "model": None,
                "iosVersion": None,
                "physicalMemoryBytes": None,
                "selectionBaselineResidentBytes": None,
                "measuredMemoryMarginBytes": None,
            }
            for slot in DEVICE_SLOTS
        },
        "limitingDevice": {
            "slot": None,
            "selectionReason": None,
        },
        "blackHole": {
            "appliedAt": "clientSpecificRouterAcl",
            "action": "drop",
            "scope": "nasIpAndPortOnly",
            "endpointUnchanged": None,
            "nwPathStatus": None,
            "icloudReachable": None,
            "nasConfigurationChanged": None,
        },
        "t091": {"samples": _t091_samples()},
        "t092": _t092_template(),
        "t093": _t093_template(),
        "t094": _t094_template(),
    }


def _artifact(role: str, artifact_format: str) -> dict[str, Any]:
    return {
        "role": role,
        "format": artifact_format,
        "sha256": None,
        "byteCount": None,
    }


def _trace_export(role: str, kind: str) -> dict[str, Any]:
    reducer_id, reducer_version = TRACE_REDUCERS[kind]
    return {
        **_artifact(role, "json"),
        "reducerId": reducer_id,
        "reducerVersion": reducer_version,
    }


def _capture(role: str) -> dict[str, Any]:
    return {
        "attempts": [
            {
                "status": None,
                "invalidReason": None,
                "artifact": _artifact(role, "trace"),
            }
        ]
    }


def _t091_samples() -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    for device in DEVICE_SLOTS:
        for condition in T091_CONDITIONS:
            file_condition = condition.lower()
            for run in range(11):
                warmup = run == 0
                role = f"T091-{device}-{file_condition}-r{run:02d}"
                if warmup:
                    role += "-warmup"
                samples.append(
                    {
                        "device": device,
                        "condition": condition,
                        "run": run,
                        "warmup": warmup,
                        "processStartSeconds": None,
                        "timelineInteractiveSeconds": None,
                        "capture": _capture(role),
                        "metricsExport": _trace_export(f"{role}-metrics", "t091Launch"),
                    }
                )
    return samples


def _t092_template() -> dict[str, Any]:
    return {
        "device": None,
        "blackHoleRun": {
            "continuous": None,
            "traversalsCompleted": None,
            "freezeOrCrash": None,
            "backgroundResumes": [
                {"traversal": traversal, "durationSeconds": None}
                for traversal in T092_BACKGROUND_TRAVERSALS
            ],
            "baselineStabilizationSeconds": None,
            "finalStabilizationSeconds": None,
            "baselineResidentBytes": None,
            "finalResidentBytes": None,
            "baselineOpenTemporaries": None,
            "finalOpenTemporaries": None,
            "finalActiveRequests": _request_counts(),
            "maxConcurrentPermits": _permit_counts(),
            "capture": _capture("T092-DX-blackhole-100"),
            "metricsExport": _trace_export(
                "T092-DX-blackhole-100-metrics",
                "t092BlackHole",
            ),
        },
        "controls": {
            "online": _t092_traversal_control("online"),
            "airplane": _t092_traversal_control("airplane"),
            "iCloudOnly": {
                "residencyOracle": "photosCloudBadgeAndLocalOnlyTerminal",
                "requests": [
                    {
                        "durationSeconds": None,
                        "terminalOutcome": None,
                        "networkBytes": None,
                        "knownLocalFollowUpSeconds": None,
                    }
                    for _ in range(T092_ICLOUD_REQUESTS)
                ],
                "freezeOrCrash": None,
                "capture": _capture("T092-DX-icloudonly-control"),
                "metricsExport": _trace_export(
                    "T092-DX-icloudonly-control-metrics",
                    "t092ICloudOnly",
                ),
            },
        },
    }


def _t092_traversal_control(condition: str) -> dict[str, Any]:
    return {
        "traversalsCompleted": None,
        "freezeOrCrash": None,
        "capture": _capture(f"T092-DX-{condition}-control"),
        "metricsExport": _trace_export(
            f"T092-DX-{condition}-control-metrics",
            "t092TraversalControl",
        ),
    }


def _request_counts() -> dict[str, Any]:
    return {
        "localThumbnail": None,
        "localOriginal": None,
        "remoteThumbnail": None,
        "remoteOriginal": None,
        "localOriginalExport": None,
        "remoteOriginalExport": None,
    }


def _permit_counts() -> dict[str, Any]:
    return {
        "localThumbnail": None,
        "localOriginal": None,
        "originalExport": None,
    }


def _t093_template() -> dict[str, Any]:
    return {
        "device": None,
        "fixtureGeneratorContract": "manifestPublishedAfterFfprobe",
        "fixtureManifestSha256": None,
        "fixtureManifestByteCount": None,
        "localCancellationAutomatedEvidence": {
            "commandId": "t093LocalCancellationXCTestV1",
            "sourceRevision": None,
            "exitCode": None,
            "artifact": _artifact("T093-local-cancellation-tests", "json"),
        },
        "cases": [
            _t093_case(adapter, operation, fixture)
            for adapter, operation, fixture in T093_CASES
        ],
    }


def _t093_case(adapter: str, operation: str, fixture: str) -> dict[str, Any]:
    case_slug = operation.lower()
    adapter_slug = "local" if adapter == "localPhotoKit" else "remote"
    role = f"T093-DX-{adapter_slug}-{case_slug}"
    is_cancel = operation == "cancel1024"
    return {
        "adapter": adapter,
        "operation": operation,
        "fixture": fixture,
        "result": None,
        "residentBaselineBytes": None,
        "residentPeakBytes": None,
        "baselineOpenTemporaries": None,
        "finalOpenTemporaries": None,
        "finalActiveRequests": {
            "localOriginalExport": None,
            "remoteOriginalExport": None,
        },
        "finalActivePermits": {"originalExport": None},
        "capture": _capture(role),
        "metricsExport": _trace_export(f"{role}-metrics", "t093OriginalShare"),
        "cancellation": (
            {
                "fraction": None,
                "stabilizationSeconds": None,
                "requestIntervalClosedSeconds": None,
                "contentLengthBytes": None,
                "bytesAtCancellation": None,
                "bytesAfterStabilization": None,
                "networkConnectionsExport": (
                    _trace_export(
                        f"{role}-network",
                        "t093RemoteNetworkCancellation",
                    )
                    if adapter == "remoteURLSession"
                    else None
                ),
            }
            if is_cancel
            else None
        ),
    }


def _t094_template() -> dict[str, Any]:
    return {
        "automatedEvidence": {
            "commandId": "t094ScopedFlutterTestsV1",
            "sourceRevision": None,
            "exitCode": None,
            "artifact": _artifact("T094-scoped-flutter-tests", "json"),
        },
        "primaryDevice": None,
        "secondaryDevice": None,
        "primaryScenarios": [
            _t094_scenario("DP", name) for name in T094_PRIMARY_SCENARIOS
        ],
        "secondaryScenarios": [
            _t094_scenario("DS", name) for name in T094_SECONDARY_SCENARIOS
        ],
    }


def _t094_scenario(device: str, name: str) -> dict[str, Any]:
    role_name = _camel_to_kebab(name)
    return {
        "name": name,
        "freezeOrCrash": None,
        "timelineUsableAfter": None,
        "staleEndpointPublished": None,
        "oldSessionSideEffectObserved": None,
        "capture": _capture(f"T094-{device}-{role_name}"),
    }


def _camel_to_kebab(value: str) -> str:
    result: list[str] = []
    for character in value:
        if character.isupper():
            result.append("-")
            result.append(character.lower())
        else:
            result.append(character)
    return "".join(result)
