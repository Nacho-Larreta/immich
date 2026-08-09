from __future__ import annotations

import os
import re
import stat
from pathlib import Path
from typing import Any

from evidence_schema import SCHEMA_VERSION
from strict_evidence import (
    EvidenceValidationError,
    parse_strict_json_bytes,
    require_bool,
    require_int,
    require_object,
    require_source_revision,
    require_string,
)
from t093_original_share import LOCAL_CANCELLATION_TESTS
from t094_reconnect_smoke import REQUIRED_TEST_SUITES


MAX_RAW_TEST_OUTPUT_BYTES = 16 * 1024 * 1024
XCTEST_RESULT_PATTERN = re.compile(
    r"Test Case '-\[RunnerTests\.LocalOriginalExporterTests (?P<name>[^]]+)\]' "
    r"(?P<result>passed|failed)"
)


def sanitize_t094_flutter_machine(
    input_path: Path,
    source_revision: str,
    exit_code: int,
) -> dict[str, Any]:
    revision = require_source_revision(source_revision, "sourceRevision")
    raw = _read_private_raw(input_path)
    test_suites: dict[int, str] = {}
    counts = {
        suite: {"passed": 0, "failed": 0, "skipped": 0}
        for suite in REQUIRED_TEST_SUITES
    }
    done_success: bool | None = None
    for index, line in enumerate(raw.splitlines()):
        if not line:
            continue
        event = require_object(
            parse_strict_json_bytes(line, f"machine[{index}]"),
            f"machine[{index}]",
        )
        event_type = event.get("type")
        if event_type == "testStart":
            test = require_object(event.get("test"), f"machine[{index}].test")
            test_id = require_int(test.get("id"), f"machine[{index}].test.id", minimum=0)
            url = require_string(test.get("url"), f"machine[{index}].test.url")
            suite = _match_suite(url)
            if suite is not None:
                test_suites[test_id] = suite
        elif event_type == "testDone":
            test_id = require_int(event.get("testID"), f"machine[{index}].testID", minimum=0)
            suite = test_suites.get(test_id)
            if suite is None:
                continue
            result = require_string(event.get("result"), f"machine[{index}].result")
            skipped = require_bool(event.get("skipped", False), f"machine[{index}].skipped")
            bucket = "skipped" if skipped or result == "skipped" else (
                "passed" if result == "success" else "failed"
            )
            counts[suite][bucket] += 1
        elif event_type == "done":
            done_success = require_bool(event.get("success"), f"machine[{index}].success")

    if done_success is None:
        raise EvidenceValidationError("flutter_machine_done_missing", "machine")
    if done_success != (exit_code == 0):
        raise EvidenceValidationError("flutter_exit_summary_mismatch", "machine")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "t094ScopedFlutterTests",
        "payload": {
            "commandId": "t094ScopedFlutterTestsV1",
            "sourceRevision": revision,
            "exitCode": exit_code,
            "suites": counts,
        },
    }


def sanitize_t093_xctest_output(
    input_path: Path,
    source_revision: str,
    exit_code: int,
) -> dict[str, Any]:
    revision = require_source_revision(source_revision, "sourceRevision")
    try:
        text = _read_private_raw(input_path).decode("utf-8")
    except UnicodeError as error:
        raise EvidenceValidationError("raw_test_output_invalid_utf8", "testOutput") from error
    outcomes: dict[str, str] = {}
    for match in XCTEST_RESULT_PATTERN.finditer(text):
        name = match.group("name")
        if name in LOCAL_CANCELLATION_TESTS:
            outcomes[name] = match.group("result")
    passed = sorted(name for name, outcome in outcomes.items() if outcome == "passed")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "t093LocalCancellationTests",
        "payload": {
            "commandId": "t093LocalCancellationXCTestV1",
            "sourceRevision": revision,
            "exitCode": exit_code,
            "passedTests": passed,
        },
    }


def _match_suite(url: str) -> str | None:
    matches = [suite for suite in REQUIRED_TEST_SUITES if url.endswith(suite)]
    if len(matches) > 1:
        raise EvidenceValidationError("ambiguous_test_suite", "machine")
    if matches:
        return matches[0]
    if "/test/" in url and url.endswith(".dart"):
        raise EvidenceValidationError("unexpected_test_suite", "machine")
    return None


def _read_private_raw(path: Path) -> bytes:
    requested = path.expanduser().absolute()
    try:
        descriptor = os.open(
            requested,
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise EvidenceValidationError("raw_test_output_unreadable", "testOutput") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise EvidenceValidationError("raw_test_output_not_regular", "testOutput")
        if stat.S_IMODE(before.st_mode) != 0o600:
            raise EvidenceValidationError("raw_test_output_not_private", "testOutput")
        if before.st_size > MAX_RAW_TEST_OUTPUT_BYTES:
            raise EvidenceValidationError("raw_test_output_oversize", "testOutput")
        chunks: list[bytes] = []
        byte_count = 0
        while chunk := os.read(
            descriptor,
            min(1024 * 1024, MAX_RAW_TEST_OUTPUT_BYTES + 1 - byte_count),
        ):
            chunks.append(chunk)
            byte_count += len(chunk)
            if byte_count > MAX_RAW_TEST_OUTPUT_BYTES:
                raise EvidenceValidationError("raw_test_output_oversize", "testOutput")
        payload = b"".join(chunks)
        after = os.fstat(descriptor)
        if _snapshot(before) != _snapshot(after) or len(payload) != after.st_size:
            raise EvidenceValidationError("raw_test_output_changed", "testOutput")
        return payload
    finally:
        os.close(descriptor)


def _snapshot(status: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        status.st_dev,
        status.st_ino,
        status.st_mode,
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
    )
