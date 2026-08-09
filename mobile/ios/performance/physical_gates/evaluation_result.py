from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum
from typing import Any


class EvaluationStatus(IntEnum):
    PASS = 0
    FAIL = 1
    INVALID = 2


@dataclass
class GateResult:
    status: EvaluationStatus = EvaluationStatus.PASS
    findings: list[dict[str, str]] = field(default_factory=list)
    metrics: dict[str, Any] = field(default_factory=dict)

    def fail(self, code: str) -> None:
        self.status = max(self.status, EvaluationStatus.FAIL)
        self.findings.append({"status": "FAIL", "code": code})

    def invalid(self, code: str) -> None:
        self.status = EvaluationStatus.INVALID
        self.findings.append({"status": "INVALID", "code": code})

    def as_json(self) -> dict[str, Any]:
        return {
            "status": self.status.name,
            "findings": self.findings,
            "metrics": self.metrics,
        }


@dataclass(frozen=True)
class EvaluationReport:
    status: EvaluationStatus
    artifact_count: int
    gates: dict[str, GateResult]

    def as_json(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "status": self.status.name,
            "artifactCount": self.artifact_count,
            "gates": {name: result.as_json() for name, result in self.gates.items()},
        }
