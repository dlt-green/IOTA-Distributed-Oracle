# v2.0.16 — Redact public no_commit diagnostics

## Security correction

Oracle nodes previously included raw execution error messages and task target URLs in the diagnostic payload submitted through `publish_no_commit`. Parser and provider errors could contain response excerpts; truncating those messages did not prevent disclosure on the public chain.

This release constructs public diagnostics using fixed error categories instead of raw error messages. The `target` field is always `null`, and the builder no longer accepts the task payload. HTTP, JSON, LLM and other failure details cannot be copied from the error message into the public diagnostic.

The `oracle_no_commit_diag_v1` schema and correlation metadata remain available: node and task identifiers, round, task type, template, reason code, stage, elapsed time and timestamp. For compatibility, `error_message` remains a string but now contains the same predefined category as `error_class`. Consumers must not expect a readable upstream error or target URL.

Detailed errors remain in operator-local logs. This change does not erase diagnostics already published on-chain and does not establish whether any historical diagnostic contained sensitive data.

## Existing protections

The task download SSRF protections and mandatory task-download TLS verification introduced in v2.0.6 remain in place. Webview wallet authentication, removal of public server-side signing and STORAGE probe destination checks introduced in v2.0.7 remain in place. This release addresses the residual diagnostic disclosure path; it does not introduce a new SSRF fix.

## Upgrade

Rebuild and recreate oracle node containers from v2.0.16 once the release is published, preserving configuration, keys and persistent state. Source updates alone do not update running containers. For source installations, install the locked dependencies with `npm ci` in `node` before building and restarting the daemon.

No Move contract deployment, on-chain migration or new environment variable is required for this correction. Verify the revision/image actually running on every node. Publishing this release does not deploy it to operator or partner infrastructure.

## Validation

Verified locally on 25 November 2026 using Node.js 24.18.0:

- `npm run test:security` in `node`: 43 tests passed, zero failures.
- Three new regression tests cover response excerpts, raw and encoded URLs, credentials, injected JSON/newlines, preservation of safe diagnostic metadata, and the assignment handler's use of the sanitized builder.
- `npm run build` in `node`: passed.
- `git diff --check`: passed.

The local dependency installation was first realigned to the existing lockfile with `npm ci --ignore-scripts --no-audit --no-fund`; no dependency manifest or lockfile change was needed. No live blockchain transaction or deployment was performed as part of this validation.
