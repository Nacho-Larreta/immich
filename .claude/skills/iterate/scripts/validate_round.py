#!/usr/bin/env python3
"""Validate the canonical markdown contract for an Immich iteration round."""

from __future__ import annotations

import re
import sys
from pathlib import Path


VALID_STATUSES = {
    "open",
    "needs-clarification",
    "in-progress",
    "resolved",
    "failed",
}
SUMMARY_LABELS = {
    "Total": None,
    "Open": "open",
    "Needs clarification": "needs-clarification",
    "In progress": "in-progress",
    "Resolved": "resolved",
    "Failed": "failed",
}
ITEM_PATTERN = re.compile(
    r"^### (FB-(\d{3})) — (.+?)\n(?P<body>.*?)(?=^### FB-|^## Decisions Log|\Z)",
    re.MULTILINE | re.DOTALL,
)


def fail(message: str) -> None:
    print(f"INVALID: {message}", file=sys.stderr)
    raise SystemExit(1)


def field(body: str, name: str) -> str:
    match = re.search(rf"^- {re.escape(name)}: (.+)$", body, re.MULTILINE)
    if not match:
        fail(f"item missing '{name}'")
    return match.group(1).strip()


def section(body: str, name: str) -> str:
    match = re.search(
        rf"^#### {re.escape(name)}\n\n(.*?)(?=^#### |\Z)",
        body,
        re.MULTILINE | re.DOTALL,
    )
    if not match or not match.group(1).strip():
        fail(f"item missing non-empty '{name}' section")
    return match.group(1).strip()


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: validate_round.py <round-file>")

    path = Path(sys.argv[1]).resolve()
    if not path.is_file():
        fail(f"round file does not exist: {path}")

    text = path.read_text(encoding="utf-8")
    for marker in ("## Summary", "## Items", "## Decisions Log"):
        if marker not in text:
            fail(f"missing heading: {marker}")

    items = list(ITEM_PATTERN.finditer(text))
    if not items:
        fail("no FB items found")

    expected_ids = [f"FB-{index:03d}" for index in range(1, len(items) + 1)]
    actual_ids = [item.group(1) for item in items]
    if actual_ids != expected_ids:
        fail(f"IDs must be unique and contiguous: expected {expected_ids}, got {actual_ids}")

    counts = {status: 0 for status in VALID_STATUSES}
    for item in items:
        body = item.group("body")
        status = field(body, "Status")
        if status not in VALID_STATUSES:
            fail(f"{item.group(1)} has invalid status '{status}'")
        counts[status] += 1

        issue_value = field(body, "Issue").strip("`")
        if issue_value == "—":
            fail(f"{item.group(1)} must link a canonical issue")
        issue_path = (path.parent / issue_value).resolve()
        if not issue_path.is_file():
            fail(f"{item.group(1)} issue does not exist: {issue_path}")

        field(body, "Severity")
        field(body, "Owner")
        field(body, "Blocked by")
        field(body, "Verification")
        section(body, "Original feedback")
        section(body, "Description")
        section(body, "Clarification")
        acceptance = section(body, "Acceptance criteria")
        if "- [" not in acceptance:
            fail(f"{item.group(1)} has no acceptance checklist")
        section(body, "History")

    for label, status in SUMMARY_LABELS.items():
        match = re.search(rf"^- {re.escape(label)}: (\d+)$", text, re.MULTILINE)
        if not match:
            fail(f"missing summary count '{label}'")
        actual = int(match.group(1))
        expected = len(items) if status is None else counts[status]
        if actual != expected:
            fail(f"summary '{label}' is {actual}, expected {expected}")

    print(f"VALID: {path} ({len(items)} items)")


if __name__ == "__main__":
    main()
