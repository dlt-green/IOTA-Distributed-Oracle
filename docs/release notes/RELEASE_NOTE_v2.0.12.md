# v2.0.12 — Preparation audit visibility and subprocess controls

## Security assessment

A supplied report described automated attempts to make STORAGE preparation access cloud metadata, loopback and private addresses, including through wildcard DNS and DNS rebinding domains. It reported approximately 900 requests using at least 25 wallets. Request counts and attacker-selected targets establish attempted abuse, not successful internal access or credential disclosure. The reporter's deployed image and successful response evidence were not supplied.

The inspected v2.0.11 source already restricted preparation fetches to HTTP/HTTPS, blocked private and reserved IP ranges, pinned validated DNS answers to connections and revalidated redirects. Task and task-schedule preparation share this transport; scheduled action preparation does not perform the STORAGE probe. Wallet signature authentication establishes key possession, not trust or permission to bypass destination checks. Disposable-wallet authentication is expected for this public preparation service.

Per-IP preparation throttling already existed in addition to per-wallet controls. The default Compose configuration already persisted audit logs. Inspection during implementation also found an existing process-wide limit of four concurrent preparations; the earlier assessment that no global cap existed was incorrect. This release strengthens that control rather than introducing it for the first time.

## Changes

- Blocked destination hostnames and machine-readable rejection codes are now written to the Webview's rotating audit log as `task_destination_blocked` events. The event originates at the client transport's actual policy rejection, including DNS and redirect denials, and is forwarded through a bounded structured stderr protocol.
- Audit records exclude URL paths, query strings, user information, credentials, task bodies and unrelated subprocess diagnostics. Structured records are JSON-encoded, validated and bounded. The API response continues to expose a generic error code rather than the blocked hostname.
- `WEBVIEW_PREPARATION_CONCURRENCY` configures the global number of reserved preparation subprocess slots per Webview process. Default: **4**. Supported range: **1–32**. Invalid values fail configuration validation. All three preparation modes share the same pool, independently of wallet, session or source IP.
- Excess work is rejected before subprocess creation with HTTP **503**, error **`PREPARATION_CAPACITY`**, and `Retry-After: 1`. Capacity denials produce a `preparation_capacity_rejected` audit event.
- Slots remain reserved until the subprocess's actual `close` event. A timeout, kill error or disconnected HTTP client cannot release a still-running subprocess slot. A factory failure before process creation releases the reservation.
- Unix preparations use their own process groups so timeout termination reaches npm/tsx descendants, with SIGKILL escalation after five seconds. Windows termination retains `taskkill /t /f`. Compose now enables `init: true` for child-process reaping.
- Combined stdout/stderr capture is bounded at 1 MB per preparation. Excess output triggers termination while retaining the slot until close.

## Upgrade and .env guidance

Rebuild and recreate the Webview using the updated source and Compose configuration. There is no Move contract deployment, new wallet key, login restriction or wallet minimum-balance requirement.

Existing installations can retain their `.env`: the default concurrency remains four. To lower it on a smaller server, add:

```dotenv
WEBVIEW_PREPARATION_CONCURRENCY=2
```

For hostname audit events, keep `WEBVIEW_AUDIT_ENABLED=true` (the default). The default `./logs/audit.log` is inside the existing `webview_audit` volume. If `WEBVIEW_AUDIT_FILE` points elsewhere, mount that directory persistently as well. Existing size and file-count rotation settings apply to the new events. Hostnames themselves may contain sensitive information; restrict operator access to the logs.

The global cap applies to one Webview process; replicas have independent pools. It limits concurrent preparations, not every incoming HTTP request or every form of distributed abuse. Proxy trust configuration still determines the effectiveness of per-client IP attribution. Authentication and rate limits do not replace the mandatory destination restrictions.

## Validation

All **54 Webview tests** and **13 client tests** passed. New coverage includes shared admission during asynchronous process creation, capacity recovery, timeout/error slot retention, output limits, logging failures, malformed diagnostic rejection, audit-file delivery and an actual child process exercising the preparation transport. Client coverage checks redaction and the blocked hostname selected by DNS and redirect denials. Existing SSRF, DNS pinning, wallet authentication, per-IP controls and audit rotation tests remain passing.

Webview/server and client TypeScript checks and the production frontend build passed. These checks used offline fixtures and a local subprocess; they did not demonstrate compromise of any deployed node or successful access to cloud metadata. Release publication does not update existing node installations automatically.
