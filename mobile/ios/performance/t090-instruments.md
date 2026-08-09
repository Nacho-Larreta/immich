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

## TC-017 cold launch

For each device and each condition:

1. Run one warm-up and exclude it.
2. Terminate the app completely between samples.
3. Capture ten cold launches from Instruments.
4. For each run, subtract Process Start from `TimelineInteractive`.
5. Sort the ten durations ascending. Nearest-rank p95 is item
   `ceil(0.95 * 10)`, therefore item 10.

Pass when p95 is at most 1.5 seconds. A trace without either source timestamp is
invalid, not a pass.

## TC-018 gallery stress

Capture baseline Resident Size and open-temporary count after stabilization. Run
100 mixed gallery traversals, including local, cached remote, cancellation, and
background/resume paths.

Pass only when:

- no freeze or crash occurs;
- active request intervals return to zero;
- no more than four `LocalThumbnailPermit` and two original permit intervals
  overlap;
- open `OriginalExportTemporary` intervals return to baseline;
- final Resident Size is at most baseline plus 64 MiB.

## TC-026 original share

Use synthetic, non-personal 256 MiB and 1 GiB originals. Capture each fixture from
request start until the lease is released or cleanup fails.

Generate and verify the exact-size originals with
`mobile/ios/performance/fixtures/generate_t093_fixtures.py`; generated media stays
under `/private/tmp` by default and must not be added to Git.

Pass only when peak Resident Size is at most 96 MiB, the 1 GiB delta is at most
1.5 times the 256 MiB delta, cancellation aborts the producer, request/permit
intervals return to zero, and temporary intervals return to baseline. An open
temporary interval is a cleanup failure and fails the run.
