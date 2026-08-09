#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Sequence

from artifact_integrity import (
    ARTIFACT_FORMAT_SUFFIXES,
    digest_artifact,
    require_private_external_directory,
    write_private_json_exclusive,
)
from evidence_schema import SCHEMA_VERSION
from evaluation_result import EvaluationStatus
from gate_evaluator import evaluate_manifest, invalid_report
from manifest_template import create_manifest_template
from strict_evidence import EvidenceValidationError, load_strict_json
from result_sanitizer import (
    sanitize_t093_xctest_output,
    sanitize_t094_flutter_machine,
)


DEFAULT_EVIDENCE_ROOT = Path("/private/tmp/immich-ios-physical-gates")
DEFAULT_FIXTURE_ROOT = Path(
    "/Volumes/T7/workspace/workspace_immich/local-performance/ios/t093-fixtures"
)
USAGE_EXIT_CODE = 64
INTERNAL_ERROR_EXIT_CODE = 70
ARTIFACT_ROLE_PATTERN = re.compile(r"T09[1-4]-[A-Za-z0-9-]+\Z")


class UsageError(ValueError):
    pass


class StrictArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    parser = StrictArgumentParser(description="Create and evaluate T091-T094 evidence")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create-template")
    create_parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_EVIDENCE_ROOT / "evidence-manifest.json",
    )

    digest_parser = subparsers.add_parser("digest-artifact")
    digest_parser.add_argument("--evidence-root", type=Path, default=DEFAULT_EVIDENCE_ROOT)
    digest_parser.add_argument("--role", required=True)
    digest_parser.add_argument(
        "--format",
        required=True,
        choices=tuple(ARTIFACT_FORMAT_SUFFIXES),
    )

    for command in ("sanitize-t093-tests", "sanitize-t094-tests"):
        sanitizer = subparsers.add_parser(command)
        sanitizer.add_argument("--input", type=Path, required=True)
        sanitizer.add_argument("--output", type=Path, required=True)
        sanitizer.add_argument("--source-revision", required=True)
        sanitizer.add_argument("--exit-code", type=int, required=True)

    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_EVIDENCE_ROOT / "evidence-manifest.json",
    )
    evaluate_parser.add_argument(
        "--evidence-root",
        type=Path,
        default=DEFAULT_EVIDENCE_ROOT,
    )
    evaluate_parser.add_argument(
        "--fixture-root",
        type=Path,
        default=DEFAULT_FIXTURE_ROOT,
    )
    evaluate_parser.add_argument("--report", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        arguments = build_parser().parse_args(argv)
        if arguments.command == "create-template":
            write_private_json_exclusive(arguments.output, create_manifest_template())
            _write_stdout(
                {
                    "schemaVersion": SCHEMA_VERSION,
                    "status": "CREATED",
                    "output": arguments.output.name,
                }
            )
            return 0
        if arguments.command == "digest-artifact":
            if ARTIFACT_ROLE_PATTERN.fullmatch(arguments.role) is None:
                raise UsageError("artifact role must be a sanitized T091-T094 role")
            evidence_root = require_private_external_directory(
                arguments.evidence_root,
                "evidence_root",
            )
            artifact_path = evidence_root / (
                arguments.role + ARTIFACT_FORMAT_SUFFIXES[arguments.format]
            )
            digest = digest_artifact(artifact_path, arguments.format, "artifact")
            _write_stdout(
                {
                    "role": arguments.role,
                    "format": arguments.format,
                    "sha256": digest.sha256,
                    "byteCount": digest.byte_count,
                }
            )
            return 0
        if arguments.command in {"sanitize-t093-tests", "sanitize-t094-tests"}:
            sanitizer = (
                sanitize_t093_xctest_output
                if arguments.command == "sanitize-t093-tests"
                else sanitize_t094_flutter_machine
            )
            summary = sanitizer(
                arguments.input,
                arguments.source_revision,
                arguments.exit_code,
            )
            write_private_json_exclusive(arguments.output, summary)
            _write_stdout(
                {
                    "schemaVersion": SCHEMA_VERSION,
                    "status": "SANITIZED",
                    "output": arguments.output.name,
                }
            )
            return 0

        try:
            manifest = load_strict_json(
                arguments.manifest,
                root=arguments.evidence_root,
                location="manifest",
            )
            report = evaluate_manifest(
                manifest,
                arguments.evidence_root,
                arguments.fixture_root,
            )
        except EvidenceValidationError as error:
            report = invalid_report(error.code)

        report_json = report.as_json()
        if arguments.report is not None:
            write_private_json_exclusive(arguments.report, report_json)
        _write_stdout(report_json)
        return int(report.status)
    except UsageError:
        _write_stdout({"schemaVersion": SCHEMA_VERSION, "status": "USAGE_ERROR"})
        return USAGE_EXIT_CODE
    except EvidenceValidationError as error:
        _write_stdout(
            {
                "schemaVersion": SCHEMA_VERSION,
                "status": "INVALID",
                "code": error.code,
            }
        )
        return int(EvaluationStatus.INVALID)
    except (OSError, RuntimeError):
        _write_stdout({"schemaVersion": SCHEMA_VERSION, "status": "INTERNAL_ERROR"})
        return INTERNAL_ERROR_EXIT_CODE


def _write_stdout(value: object) -> None:
    sys.stdout.write(json.dumps(value, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
