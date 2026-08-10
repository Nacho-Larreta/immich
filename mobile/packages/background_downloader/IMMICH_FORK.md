# Immich background_downloader fork

- Upstream: `background_downloader` 9.5.4
- Source: https://github.com/781flyingdutchman/background_downloader
- Imported from the published 9.5.4 package without examples, documentation, or upstream tests.

This fork adds an iOS request-context bridge used by Immich's native networking boundary. Tasks are bound to the request-context revision that supplied their credentials. Context replacement cancels active tasks, stale tasks cannot resume, redirect, challenge, or publish callbacks, and session configuration does not retain authentication headers or cookies.

Authenticated HTTP endpoints always use a cancelable foreground session because iOS background sessions can outlive the process. HTTPS may use the background session; when iOS recreates it, every restored task without an in-process binding is cancelled before the plugin processes callbacks and can be retried from Dart. Parallel download probes use the same revisioned foreground delegate instead of `URLSession.shared`.

Keep changes outside `ios/background_downloader/Sources/background_downloader/` limited to dependency metadata. When updating upstream, replace the imported package first and then reapply the request-context patch with its Runner integration tests green.
