# T091-T094 physical iOS gates

This runner turns the physical-device protocol into a fail-closed evidence gate. It
does not drive a phone, configure a router, generate large fixtures, or infer values
from an Instruments schema that has not been observed yet.

## Evidence workspace

Keep every generated artifact outside Git and private to the current user:

```sh
IMMICH_EVIDENCE_ROOT=/private/tmp/immich-ios-physical-gates
mkdir -p "$IMMICH_EVIDENCE_ROOT"
chmod 700 "$IMMICH_EVIDENCE_ROOT"
python3 mobile/ios/performance/physical_gates/physical_gate_runner.py \
  create-template \
  --output "$IMMICH_EVIDENCE_ROOT/evidence-manifest.json"
```

Schema v2 uses one physical test subject, always identified as `D1`. Use only `D1`
in filenames and the manifest. Never persist a device name,
UDID, account, URL, IP address, asset identifier, original filename, error body, or
screen containing personal media. `build.bundleIdentifier` is the observed bundle
identifier of the installed build; `build.sourceRevision` is the exact Git revision
from which that build was produced.

The D1 record keeps the model, iOS version, physical memory, and a 30-second
stabilized VM Tracker resident-size baseline. D1 is the subject for T091-T094 and
the final T108 install/smoke. Other TestFlight participants keep access to the same
build but do not repeat the physical gates.

## Artifact integrity

Every artifact has a deterministic role; its path is derived by the runner and is
never read from the manifest. A trace role maps to `<role>.trace`; every persisted
sanitized export used by T091-T094 maps to `<role>.json`. Produce the record to paste into the
matching manifest slot with:

```sh
python3 mobile/ios/performance/physical_gates/physical_gate_runner.py \
  digest-artifact \
  --evidence-root "$IMMICH_EVIDENCE_ROOT" \
  --role T091-D1-airplane-r00-warmup \
  --format trace
```

Regular exports use SHA-256 over their bytes. A `.trace` is a bundle, so its digest
is SHA-256 over a domain-separated, lexicographically ordered stream of directory
entries, relative names, sizes, and per-file SHA-256 digests. Symlinks, special
files, empty artifacts, changed bytes, reused physical evidence, and mismatched byte
counts make the manifest `INVALID`.

Raw traces remain local and private. A sanitized JSON export and its manifest
reference carry the exact reducer ID and version, use an allowlisted schema, bind to
the SHA-256 of the source trace, and contain only the aggregate
timing/count/memory fields required by its gate. It is reducer output, not a manual
claim. Unknown keys, free-form descriptions, or any personal field forbidden above
make the evidence invalid.

## Instruments capture and export

Set the device selector and installed app target only in the current shell. Do not
copy either value into evidence:

```sh
IMMICH_DEVICE_SELECTOR='<connected device selector>'
IMMICH_APP_TARGET='<installed app launch target>'
xcrun xctrace record \
  --template 'App Launch' \
  --instrument 'Points of Interest' \
  --instrument 'VM Tracker' \
  --device "$IMMICH_DEVICE_SELECTOR" \
  --output "$IMMICH_EVIDENCE_ROOT/T091-D1-airplane-r00-warmup.trace" \
  --launch -- "$IMMICH_APP_TARGET"
```

Remote T093 cancellation adds `--instrument 'Network Connections'`. Do not attach
to an already running app for T091; Instruments must launch it.

The first real trace establishes the Xcode 26.5 schema. Export its table of contents
without inventing an XPath:

```sh
T091_TOC=$(mktemp /private/tmp/immich-t091-toc.XXXXXX.xml)
chmod 600 "$T091_TOC"
xcrun xctrace export \
  --input "$IMMICH_EVIDENCE_ROOT/T091-D1-airplane-r00-warmup.trace" \
  --toc \
  --output "$T091_TOC"
```

The exact `--xpath` and trace reducer remain deliberately deferred until that TOC is
reviewed and frozen in this runbook. Do not fabricate a query from another Xcode
version and do not hand-author the sanitized JSON from values visible in Instruments.
Until the XPath and reducer are frozen, trace-derived metrics are unverifiable and
the production evaluator returns `INVALID` with `trace_reducer_unavailable`; there
is no CLI switch to bypass this. The first reviewed TOC unlocks a code change that
pins the XPath, reducer implementation, ID, version, and registry entry together.
Changing IDs in a manifest cannot register a reducer. Once frozen, export to a mode-`0600` transient
XML file outside the evidence directory, run the pinned reducer, and persist only
its allowlisted JSON result.

## Controlled conditions

`online` means the current endpoint responds normally. `airplane` means radios are
disabled before recording. `blackHole` means a client-specific router ACL performs
`DROP` only for that iPhone's traffic to the existing NAS IP and application port:

- the endpoint string stays unchanged;
- `NWPath` remains `satisfied`;
- unrelated internet and iCloud remain reachable;
- no DNS rewrite, reject response, timeout proxy, NAS configuration, container, or
  firewall change is allowed.

Verify the ACL match and the iCloud control before and after the gate. If any of
these properties is false, the capture is not valid black-hole evidence.

## T091: cold launch

Run D1 in `online`, `airplane`, and `blackHole`. Preserve the same session,
Drift database, and caches; do not reinstall or clear data. Per cell:

1. Fix the condition and terminate the app completely.
2. Capture `r00-warmup`, then `r01` through `r10` using the canonical filename, for
   example `T091-D1-airplane-r00-warmup.trace`.
3. A valid trace has Process Start and exactly one `TimelineInteractive`.
4. Record both timestamps; the runner derives every duration.

The warm-up is excluded. With ten measured samples, nearest-rank p95 is the maximum.
Only `airplane` and `blackHole` must be at most 1.5 seconds; `online` is a control
with no additional threshold.

Use `status=freeze` when the app freezes, crashes, or never emits
`TimelineInteractive`; that is a product `FAIL`, never an acquisition exclusion.
Use `status=invalid` only for `device_disconnect`, `instruments_error`, or
`trace_corrupt`, retain and hash that failed acquisition, then append at most one
attempt named `<role>-retry1`. A second invalid acquisition leaves the gate
`INVALID`. A slow sample is not invalid evidence and cannot be rerun away.

## T092: gallery stress

Run one continuous black-hole trace on D1. Stabilize the open
timeline for 30 seconds, record VM Tracker `Resident Size` and open temporary count,
then perform exactly 100 fixture-only traversals:

`timeline -> scroll three viewports and back -> local -> cached remote -> remote
cache miss -> start/cancel original -> timeline`

At traversals 10, 20, ..., 100, background the app for at least five seconds and
resume. After traversal 100, remain idle on the timeline for 30 seconds before the
final readings. Run three separate directed controls:

- five online traversals;
- five airplane traversals;
- five iCloud-only local requests.

For each iCloud-only request, first confirm the Photos cloud badge, request with the
app's local-only path, and require the typed `iCloudUnavailable` terminal plus the
`LocalOriginalRequest` interval to close within 1 second with zero network bytes.
Immediately request a known-local thumbnail and require completion within 1 second;
this proves the cloud asset did not occupy the local queue.

Pass requires no freeze/crash, final request intervals all zero, open temporaries
exactly equal to baseline, final Resident Size no more than baseline + 64 MiB, and
separate maxima `LocalThumbnailPermit <= 4`, `LocalOriginalPermit <= 2`, and
`OriginalExportPermit <= 2`.

## T093: original share

Generate fixtures with the existing `fixtures/generate_t093_fixtures.py`; the active
private fixture root is
`/Volumes/T7/workspace/workspace_immich/local-performance/ios/t093-fixtures`. It is
outside the `immich` Git worktree and avoids the nearly-full internal disk. The
runner re-hashes the generator manifest and both fixture files, checks exact
logical/allocation sizes, and relies on the generator's publish-last contract that
runs `ffprobe` before `manifest.json`.

Run this exact matrix on D1:

| Adapter | Success 256 MiB | Success 1 GiB | Cancel 1 GiB |
|---|---:|---:|---:|
| local PhotoKit | required | required | required |
| remote URLSession | required | required | required |

Cancel between 25% and 50%. Every case must finish with both export request
intervals and `OriginalExportPermit` at zero and open temporaries exactly at
baseline. Absolute VM Tracker `Resident Size` peak must be at most 96 MiB. Per
adapter, using success runs only, the runner enforces
`2 * delta(1 GiB) <= 3 * delta(256 MiB)`.

For local cancellation, `LocalOriginalExportRequest` and its permit must close
within one second, stay closed for two seconds, and cleanup must return to baseline;
the focused native cancellation tests are the deterministic producer oracle. For
remote cancellation, also export Network Connections and record cumulative bytes at
cancel and after at least two stable seconds. They must be equal and below the exact
1 GiB `Content-Length`. Missing Network Connections evidence is `INVALID`; bytes
that continue or reach Content-Length are `FAIL`.

From `mobile`, capture and sanitize the focused native oracle at the installed
build's source revision. The raw XCTest log is transient and must never be placed in
the evidence directory:

```sh
T093_RAW=$(mktemp /private/tmp/immich-t093-xctest.XXXXXX.log)
chmod 600 "$T093_RAW"
xcodebuild test \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -destination "platform=iOS Simulator,id=$IMMICH_SIMULATOR_ID" \
  -only-testing:RunnerTests/LocalOriginalExporterTests \
  > "$T093_RAW" 2>&1
T093_EXIT=$?
python3 ios/performance/physical_gates/physical_gate_runner.py \
  sanitize-t093-tests \
  --input "$T093_RAW" \
  --output "$IMMICH_EVIDENCE_ROOT/T093-local-cancellation-tests.json" \
  --source-revision "$IMMICH_SOURCE_REVISION" \
  --exit-code "$T093_EXIT"
```

Remove the transient log after the sanitizer succeeds. The evaluator requires the
exact allowlisted test set, source revision, real exit code, and sanitized artifact;
a boolean assertion or opaque log hash is not native proof.

## T094: reconnect, lifecycle, and session epoch

Run the current focused deterministic evidence from `mobile` at the same source
revision as the installed build. Keep `--machine` output transient because it can
contain paths, test names, and error text:

```sh
T094_RAW=$(mktemp /private/tmp/immich-t094-flutter.XXXXXX.jsonl)
chmod 600 "$T094_RAW"
flutter test \
  test/domain/services/server_reachability_coordinator_test.dart \
  test/infrastructure/adapters/reconciliation/server_reconciliation_adapter_test.dart \
  test/providers/session_work_provider_test.dart \
  test/routing/auth_guard_test.dart \
  -j 1 \
  --machine > "$T094_RAW"
T094_EXIT=$?
python3 ios/performance/physical_gates/physical_gate_runner.py \
  sanitize-t094-tests \
  --input "$T094_RAW" \
  --output "$IMMICH_EVIDENCE_ROOT/T094-scoped-flutter-tests.json" \
  --source-revision "$IMMICH_SOURCE_REVISION" \
  --exit-code "$T094_EXIT"
```

Remove the transient machine output after the sanitizer succeeds. Record its real
exit code in the manifest; it must be zero. The evaluator parses the allowlisted
per-suite counts and rejects missing, unexpected, failed, or source-mismatched
evidence. These tests are the
evidence for exactly one reconciliation, at most one coalesced rerun, and rejection
of stale-session completions. Do not add or claim epoch/generation signposts.

On D1 capture the four named scenarios from the template:
black-hole to online during a probe, background/resume during sync, logout/login
during a probe, and logout/login during sync. Each must return to a usable timeline
without freeze/crash, stale endpoint publication, or an observable side effect from
the old session. No second-device matrix is part of schema v2.

## Evaluate

After filling every non-personal field and artifact record:

```sh
python3 mobile/ios/performance/physical_gates/physical_gate_runner.py \
  evaluate \
  --manifest "$IMMICH_EVIDENCE_ROOT/evidence-manifest.json" \
  --evidence-root "$IMMICH_EVIDENCE_ROOT" \
  --fixture-root /Volumes/T7/workspace/workspace_immich/local-performance/ios/t093-fixtures \
  --report "$IMMICH_EVIDENCE_ROOT/evaluation-report.json"
```

Exit `0` is `PASS`, `1` is observed product `FAIL`, and `2` is incomplete,
malformed, or unverifiable evidence (`INVALID`). CLI usage errors exit `64`; an
unexpected runner fault exits `70`. Unknown JSON keys, duplicate keys, non-finite
numbers, booleans used as numbers, missing matrix cells, reused traces, and hash or
byte-count drift all fail closed.

## Runner tests

```sh
PYTHONPYCACHEPREFIX=/private/tmp/immich-physical-gates-pycache \
  python3 -m unittest discover \
  -s mobile/ios/performance/physical_gates \
  -p 'test_*.py'
```

The suite uses only tiny synthetic files; it never generates the 256 MiB or 1 GiB
fixtures and never talks to a device, router, NAS, or network.
