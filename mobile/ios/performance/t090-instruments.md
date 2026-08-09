# T090 iOS Instruments protocol

This protocol is the source of truth for TC-017, TC-018, and TC-026. App logs,
MetricKit, Drift, and wall-clock timestamps are not valid substitutes for launch or
memory evidence.

## Evidence header

Record these non-personal fields beside every trace:

- device model;
- iOS version;
- Immich marketing version and build number;
- condition: airplane mode, controlled black-hole, or online;
- run number and whether the run is the excluded warm-up;
- fixture size for share runs: 256 MiB or 1 GiB;
- the observed bundle identifier of the installed build
  (`Bundle.main.bundleIdentifier`).

Do not record asset names, identifiers, paths, URLs, accounts, request errors, or
screens containing personal media.

## Instruments setup

1. Use a physical iPhone and select the installed build under test.
2. Create a trace containing App Launch, Points of Interest, and VM Tracker.
3. Launch the process from Instruments. Process Start comes only from the App
   Launch/process lifecycle track.
4. Read resident memory only from VM Tracker's Resident Size series.
5. Keep Points of Interest visible for the installed build's observed bundle
   identifier. Do not hardcode a subsystem or add a custom category filter.

The app emits only one launch event: `TimelineInteractive`. Its timestamp is the
Flutter post-frame callback after the first successful timeline data render. Empty
data is valid; loading, error, and an unmounted page are not.

## Static signposts

| Signpost | Type | Meaning |
|---|---|---|
| `TimelineInteractive` | event | Main timeline's first successful post-frame render |
| `LocalThumbnailRequest` | interval | accepted local thumbnail request |
| `LocalOriginalRequest` | interval | accepted local original request |
| `RemoteThumbnailRequest` | interval | accepted remote thumbnail request |
| `RemoteOriginalRequest` | interval | accepted remote original request |
| `LocalOriginalExportRequest` | interval | accepted local export request |
| `RemoteOriginalExportRequest` | interval | accepted remote export request |
| `LocalThumbnailPermit` | interval | granted local thumbnail permit |
| `LocalOriginalPermit` | interval | granted local original permit |
| `OriginalExportPermit` | interval | granted original export permit |
| `OriginalExportTemporary` | interval | owned temporary directory lifetime |

Interval IDs are unique and every terminal resource finishes its own interval
idempotently. A temporary interval transfers with its lease and ends only after a
successful remove. A failed cleanup intentionally leaves the interval open, making
the leak visible in the trace. Payload format and names are static; payload values
are integer kind codes only.

## Executable evidence

The executable manifest, artifact-integrity rules, capture names, and physical
runbook live in `mobile/ios/performance/physical_gates/README.md`. Generated
manifests, traces, exports, fixture media, and reports stay outside Git under a
private `/private/tmp` directory. Schema v2 has one physical subject, always `D1`;
evidence
must not contain device names, UDIDs, accounts, URLs, IP addresses, asset IDs,
original paths, or personal media.

The first real Xcode 26.5 trace must be exported with `xctrace export --toc` to a
private transient file outside the evidence directory. The exact XPath and reducer
for sanitized aggregate JSON are intentionally deferred until that TOC exists; do
not copy a schema or XPath from another Xcode version and do not hand-author reducer
output. Until both are frozen, trace-derived evidence is unverifiable and the gate
is `INVALID` with `trace_reducer_unavailable`. The first reviewed TOC unlocks a
reviewed code change that pins XPath, reducer ID/version, implementation, and the
production registry entry; manifest data and CLI arguments cannot enable a reducer.

## TC-017 / T091 cold launch

For D1 and each condition:

1. Run one warm-up and exclude it.
2. Terminate the app completely between samples.
3. Capture ten cold launches from Instruments.
4. For each run, subtract Process Start from `TimelineInteractive`.
5. Sort the ten durations ascending. Nearest-rank p95 is item
   `ceil(0.95 * 10)`, therefore item 10.

Use the canonical name `T091-D1-airplane-r00-warmup.trace` and the corresponding
slot/condition/run names from the generated template. Airplane and controlled
black-hole p95 must be at most 1.5 seconds. Online is a control and has no additional
threshold.

A freeze, crash, or missing `TimelineInteractive` is a failure, not an invalid
capture. Only `device_disconnect`, `instruments_error`, or `trace_corrupt` can mark
acquisition invalid. Preserve and hash that trace; one `-retry1` capture is allowed.
A second invalid acquisition leaves the gate invalid.

## TC-013 / TC-018 / T092 gallery stress

Use D1. Record its physical memory and 30-second VM Tracker resident-size baseline
as evidence metadata. Under controlled black-hole, capture one continuous run of
exactly 100 fixture-only traversals. Take
baseline after 30 seconds idle on the loaded timeline and final readings after
another 30 seconds idle. Every tenth traversal backgrounds the app for at least five
seconds before resume. Run separate controls of five online traversals, five
airplane traversals, and five iCloud-only local requests.

The iCloud-only oracle is a Photos cloud-badge asset requested through the local-only
path: terminal `iCloudUnavailable` within one second, zero network bytes, followed
immediately by a known-local thumbnail completing within one second.

Pass only when:

- no freeze or crash occurs;
- active request intervals return to zero;
- `LocalThumbnailPermit` overlap is at most four;
- `LocalOriginalPermit` overlap is at most two;
- `OriginalExportPermit` overlap is at most two;
- open `OriginalExportTemporary` intervals return to baseline;
- final Resident Size is at most baseline plus 64 MiB.

## TC-026 / T093 original share

Use synthetic, non-personal 256 MiB and 1 GiB originals. Capture each fixture from
request start until the lease is released or cleanup fails.

Generate and verify the exact-size originals with
`mobile/ios/performance/fixtures/generate_t093_fixtures.py`; generated media stays
under `/private/tmp` by default and must not be added to Git.

On D1, execute success 256 MiB, success 1 GiB, and cancel 1 GiB for
both local PhotoKit and remote URLSession adapters. Cancel between 25% and 50%.

Pass only when absolute peak Resident Size is at most 96 MiB, each adapter's 1 GiB
success delta is at most 1.5 times its 256 MiB success delta, request/permit intervals
return to zero, and temporary intervals return exactly to baseline. An open temporary
interval is a cleanup failure and fails the run.

For remote cancellation, Network Connections must show cumulative bytes unchanged
for at least two seconds after cancellation and still below the exact 1 GiB
Content-Length. Missing Network Connections evidence makes the gate invalid; bytes
that continue or reach Content-Length fail it. Local cancellation uses prompt
request/permit closure plus the focused native cancellation tests as its producer
oracle.

Local cancellation additionally requires a sanitized result from the focused
`RunnerTests/LocalOriginalExporterTests` XCTest invocation, bound to the installed
build's source revision and real exit code. Raw XCTest output stays in a mode-`0600`
transient file outside evidence and is deleted after sanitization; manual booleans
and opaque hashes are not proof.

## TC-005 / TC-006 / TC-007 / T094 composite evidence

Focused coordinator, reconciliation, lifecycle, and auth tests prove exactly one
reconciliation, at most one coalesced rerun, and rejection of old-session
completions. Physical traces prove black-hole to online, background/resume, and
logout/login remain responsive and never visibly publish stale state on the primary
device D1. There is no second-device matrix. T108 also uses D1 for final install and
smoke; other TestFlight participants retain access without repeating the physical
gates. Do not add epoch or generation telemetry solely for this gate.

Run the four exact Flutter test paths listed in `physical_gates/README.md` with
`--machine`, but redirect raw JSONL to a mode-`0600` transient file outside evidence.
Persist only the sanitizer's allowlisted JSON summary containing command identity,
source revision, real exit code, and per-suite counts.
