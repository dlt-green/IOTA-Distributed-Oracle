# v2.0.17 — Signed transaction recovery and node log rotation

## Transaction recovery

The daemon now saves signed transaction bytes and the signature before submission. If a later lookup explicitly reports that the pending digest cannot be found, it can retransmit the exact same bytes and signature, including after a process restart. It does not rebuild the transaction, refresh gas or sign a replacement.

Before retransmission, the daemon verifies the digest, signature, sender and journal context. Replay attempts use a persisted exponential delay from 2 seconds up to 5 minutes. Lookup transport failures do not trigger replay; ambiguous replay failures retain the pending transaction. Confirmed outcomes resolve the journal while preserving effects and workflow separation.

Old journals remain readable. Pending records without signed bytes cannot be replayed and report `LEGACY_JOURNAL_NO_SIGNED_TRANSACTION` when their digest is unavailable. This release does not automatically unblock historical pending records. Do not delete journals solely because an explorer or RPC cannot find a digest.

An unavailable RPC, expired transaction or unusable input can still require operator intervention. New writes from the same wallet remain blocked while the previous outcome is unresolved. Run only one daemon per wallet/journal. Protect journals and backups: they contain signed execution authorizations, although no private key is stored.

See [transaction recovery](../TRANSACTION_RECOVERY.md) for details.

## Node log rotation

The Testnet node Compose configuration now explicitly uses `json-file` logging with `max-size: "50m"` and `max-file: "10"`.

Rotation applies to each container. It does **not** preserve logs when that container is removed and recreated by an update. Export required logs before upgrading or configure an external persistent logging service. This release does not add automatic log export to `update.sh`.

## Upgrade

Export existing container logs first, then rebuild and recreate the node containers from v2.0.17. Preserve wallet keys, environment configuration, journal paths and persistent storage volumes. Recreating the containers is required to apply the logging options.

No Move deployment, on-chain migration or new environment variable is required. Existing Webview wallet authentication and v2.0.16 diagnostic redaction remain unchanged. Publishing the release does not update partner installations automatically.

## Validation

- Node regression/security suite: 54 tests passed, including recovery in a fresh process, identical retransmission, legacy journals, invalid authorization, checkpoint delays and ambiguous RPC failures.
- Node TypeScript build and `git diff --check`: passed.
- Updated Compose configuration: validated with Docker Compose.
- Recovery tests use real serialization and signatures with mocked RPC responses; no live transaction replay was performed.
