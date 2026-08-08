# Widget Session Token in Query Parameters

## Context

The iOS and Android widgets request Immich media with the session key encoded in the request URL query string. This behavior predates the offline endpoint activation work and is not required by its native request-context contract.

## Debt

Credentials in URLs can be retained by reverse-proxy access logs, server telemetry, crash reports, or URL diagnostics. Unlike request headers, query parameters commonly survive in operational records after the request completes.

## Risk

- A valid Immich session token can remain in NAS or reverse-proxy logs.
- Anyone with access to those logs may be able to replay the token until it expires or is revoked.
- Redaction rules that cover authorization headers may not cover query parameters.

## Proposed Fix

- Move widget authentication to an `Authorization` header or a short-lived, narrowly scoped widget credential.
- Reject or deprecate token-bearing widget URLs after both native clients migrate.
- Add iOS and Android tests proving generated request URLs contain no credentials.
- Document a log-redaction and token-rotation migration for existing installations.

## Current Mitigation

The endpoint activation work refreshes and clears widget credentials transactionally, but it does not change the widget transport contract. Keep NAS and reverse-proxy logs private and rotate the Immich session if those logs are exposed until the transport is migrated.
