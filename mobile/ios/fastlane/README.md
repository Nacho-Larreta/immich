fastlane documentation
----

The maintained [private-fork release guide](RELEASING.md) contains authentication,
signing, safety gates, and accepted release baselines. Read it before running a lane.

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios gha_testflight_dev

```sh
[bundle exec] fastlane ios gha_testflight_dev
```

iOS Development Build to TestFlight (requires separate bundle ID)

### ios gha_release_prod

```sh
[bundle exec] fastlane ios gha_release_prod
```

iOS Release to TestFlight

### ios nacho_latest_prod_build

```sh
[bundle exec] fastlane ios nacho_latest_prod_build
```

Print latest Nacho Fotos TestFlight build

### ios nacho_upload_current_prod

```sh
[bundle exec] fastlane ios nacho_upload_current_prod
```

Upload the already configured Nacho Fotos release build to TestFlight

### ios release_manual

```sh
[bundle exec] fastlane ios release_manual
```

iOS Manual Release

### ios nacho_testflight_preflight_prod

```sh
[bundle exec] fastlane ios nacho_testflight_preflight_prod
```

Read-only fail-closed preflight for the exact Nacho Fotos TestFlight release

### ios nacho_prepare_signing_prod

```sh
[bundle exec] fastlane ios nacho_prepare_signing_prod
```

Explicitly import or create the production signing identity and exact three profiles

### ios nacho_build_exact_prod

```sh
[bundle exec] fastlane ios nacho_build_exact_prod
```

Build and locally verify one exact production IPA without remote actions

### ios nacho_upload_exact_prod

```sh
[bundle exec] fastlane ios nacho_upload_exact_prod
```

Upload one exact prebuilt IPA after a second fail-closed preflight

### ios nacho_finalize_testflight_prod

```sh
[bundle exec] fastlane ios nacho_finalize_testflight_prod
```

Resume processing and idempotently associate the exact build with its internal group

### ios gha_build_only

```sh
[bundle exec] fastlane ios gha_build_only
```

iOS Build Only (no TestFlight upload)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
