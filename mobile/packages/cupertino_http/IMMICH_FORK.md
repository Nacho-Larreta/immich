# Immich Cupertino HTTP fork

- Upstream repository: `https://github.com/mertalev/http`
- Baseline commit: `a0a933358517c6d01cff37fc2a2752ee2d744a3c`
- Baseline package: `pkgs/cupertino_http`
- Backported concept: task reaper from `21e146ad5bdabb3806abb92c9f51314c2348acbb`

This package is vendored so Immich can audit and test shared-session task
ownership, cancellation, terminal delivery, and isolate-shutdown behavior.
Keep the vendored diff limited to those lifecycle guarantees. Do not update it
by copying the later upstream package wholesale; that would also import the
unrelated Objective-C binding migration.

The native lifecycle harness can be run without a simulator by compiling the
two Swift sources together with `test_native/StreamingTaskLifecycleHarness.swift`.
