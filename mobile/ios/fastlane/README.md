# iOS Fastlane

Production TestFlight releases are split into explicit, resumable phases. None of these lanes creates testers, invites users, resolves export compliance, uploads implicitly, or logs identifiers and personal data.

## Authentication

Every protected lane requires an explicit App Store Connect key configuration:

- `ASC_KEY_TYPE`: `team` or `individual`.
- `ASC_KEY_ID`: key identifier.
- `ASC_KEY_PATH`: full path to the existing `.p8`; the path is never derived.
- `ASC_ISSUER_ID`: UUID for a team key, or the exact sentinel `none` for an individual key.

Release lanes also require `ASC_TEAM_ID` and `DEVELOPER_PORTAL_TEAM_ID` as separate values.

## Exact release inputs

The preflight, upload, and finalizer require all of these values with no defaults:

- `TESTFLIGHT_INTERNAL_GROUP`
- `TESTFLIGHT_TESTER_EMAIL_1`
- `TESTFLIGHT_TESTER_EMAIL_2`
- `EXPECTED_VERSION`
- `EXPECTED_PREVIOUS_BUILD_NUMBER`
- `EXPECTED_BUILD_NUMBER`
- `IPA_PATH`

The two emails must be distinct. Build numbers must be canonical positive decimal integers and the expected build must equal the previous build plus one.

## Protected production workflow

Run each phase separately and inspect its sanitized result before continuing:

```sh
bundle exec fastlane ios nacho_testflight_preflight_prod
bundle exec fastlane ios nacho_upload_exact_prod
bundle exec fastlane ios nacho_finalize_testflight_prod
```

- `nacho_testflight_preflight_prod` is read-only. It verifies the exact app, version/build expectation, internal group, and both eligible testers.
- `nacho_upload_exact_prod` copies the IPA into a private `0600` snapshot, validates its exact bundle ID, version, build, and explicit exempt-encryption declaration, repeats the preflight, revalidates the snapshot identity and digest, uploads only that private copy, and cleans it afterward. Cleanup uses fd-relative exclusive moves into random quarantine names; if another file wins the final-name race, that racer is restored rather than overwritten or deleted.
- `nacho_finalize_testflight_prod` never uploads. It polls allowlisted states with a monotonic timeout, verifies expiration/encryption invariants before mutation and again after the final refetch, and idempotently associates the build with the internal group.

Read-only App Store Connect requests retry only `429` and `5xx` responses within a bounded monotonic budget. `Retry-After` is sanitized and capped. Authorization/not-found/validation responses are terminal, while ambiguous `5xx` mutation outcomes are resolved only by refetching state.

Legacy production release lanes fail explicitly. The separate development bundle workflow remains available.

## Signing preparation

Signing is never prepared by the upload lane. Use `nacho_prepare_signing_prod` separately.

Both signing modes require a team API key. Normal import mode requires:

- `SIGNING_PREPARATION_MODE=import`
- `SIGNING_P12_PATH`
- `SIGNING_P12_PASSWORD`
- `SIGNING_CERTIFICATE_SHA256`
- `SIGNING_CERTIFICATE_ID`
- `DEVELOPER_PORTAL_TEAM_ID`
- `RUNNER_PROFILE_PATH`
- `SHARE_EXTENSION_PROFILE_PATH`
- `WIDGET_EXTENSION_PROFILE_PATH`

The lane verifies that the P12 contains a matching certificate/private-key pair, consumes the exact portal certificate ID, matches its fingerprint, and confirms that the exact three profiles match their bundle IDs and certificate before importing anything.

Creating a new identity is exceptional. It additionally requires `SIGNING_PREPARATION_MODE=create_authorized`, `SIGNING_CREATE_AUTHORIZED=true`, `SIGNING_P12_PASSWORD`, and a dedicated empty `SIGNING_BACKUP_DIRECTORY` outside the Git repository. That directory must be a non-symlink owned by the current user with exact mode `0700`. The lane creates one distribution identity, atomically replaces its regular private-key output with a verified encrypted PKCS#12 file with mode `0600`, verifies the returned portal certificate ID/fingerprint, and obtains exactly three profiles with explicit `force: false` so environment defaults cannot trigger remote deletion. A profile is counted ready only after its regular non-symlink file, bundle ID, and certificate are verified. Failed creation removes only plaintext private-key inodes still owned by the operation through fd-relative exclusive quarantine moves; racers are preserved. The lane never revokes or deletes certificates or profiles, and always emits a sanitized partial-state summary.

Do not put any key, password, tester email, certificate, or provisioning profile in Git or command history.

## Scoped tests

```sh
cd mobile/ios/fastlane
PATH=/opt/homebrew/opt/ruby/bin:$PATH /opt/homebrew/opt/ruby/bin/bundle exec ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
```

## Private-fork release closure

Treat a green archive as an intermediate artifact, not as release acceptance.
Close a private iOS release only after all of these boundaries are independently
verified:

1. The Git worktree is clean and the intended commit is present on `origin/main`.
2. Pigeon outputs are reproducible and scoped Dart, Swift and Fastlane contracts
   pass from the release commit.
3. Every embedded native asset is an `iphoneos` binary, has the expected Team ID,
   and passes deep strict code-sign verification. Never reuse simulator-produced
   native assets in a device archive.
4. Install the Release build in place on the physical iPhone so persisted session
   and local-library data participate in the smoke.
5. Exercise cold launch, installed-session recovery, offline local media, login and
   relogin, remote thumbnails/originals, sync/cloud actions, local and remote Share,
   and eligible backup. Confirm the process remains alive and no new crash report
   appears.
6. Only then run the protected preflight, exact upload and finalizer phases. Keep
   build, upload and finalization separate and resumable.

Authenticated native work must remain bound to one immutable context identity:
exact origin, session epoch and native generation. Context replacement fences and
drains old HTTP, WebSocket, image, export and background work before admitting the
new context. Local PhotoKit reads and local Share remain server-independent.

Operationally, large DerivedData and temporary build outputs may live on an
external volume, but CoreSimulator still consumes the system data volume. When
that volume is exhausted, prefer the physical-device gate; do not report an iOS
test as passing when its runner could not be installed.
