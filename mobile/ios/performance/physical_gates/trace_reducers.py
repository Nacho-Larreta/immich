from __future__ import annotations

from dataclasses import dataclass
from typing import Final

from strict_evidence import EvidenceValidationError


TRACE_REDUCERS: Final[dict[str, tuple[str, int]]] = {
    "t091Launch": ("immich.xctrace.t091-launch", 1),
    "t092BlackHole": ("immich.xctrace.t092-black-hole", 1),
    "t092TraversalControl": ("immich.xctrace.t092-traversal-control", 1),
    "t092ICloudOnly": ("immich.xctrace.t092-icloud-only", 1),
    "t093OriginalShare": ("immich.xctrace.t093-original-share", 1),
    "t093RemoteNetworkCancellation": (
        "immich.xctrace.t093-remote-network-cancellation",
        1,
    ),
}


@dataclass(frozen=True)
class TraceReducerRegistry:
    registered: frozenset[tuple[str, int]] = frozenset()

    def require(self, kind: str, reducer_id: str, reducer_version: int) -> None:
        expected = TRACE_REDUCERS.get(kind)
        if expected != (reducer_id, reducer_version):
            raise EvidenceValidationError("unknown_trace_reducer", kind)
        if expected not in self.registered:
            raise EvidenceValidationError("trace_reducer_unavailable", kind)
