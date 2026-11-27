# Pending transaction recovery

The daemon persists the transaction bytes (Base64) and serialized signature before submitting a new transaction. The journal also retains the digest, operation label, intent, wallet identity, journal path and previously confirmed effects. Existing file permissions and atomic replacement apply to these records.

When a pending digest exists, the daemon first queries its outcome. An explicit RPC response `Could not find the referenced transaction [<digest>]` permits retransmission of the stored bytes and signature. Timeouts and other lookup errors do not trigger retransmission. The daemon verifies the saved digest, transaction sender, signature and journal context before replaying; it does not refresh gas, rebuild the transaction or sign again.

Replay failures use a persisted exponential delay starting at 2 seconds and capped at 5 minutes. Each invocation first checks for an existing outcome, including during the replay delay. Successful recovery of a different workflow asks the current caller to retry its own operation rather than treating the recovered result as its result. Definitive on-chain failure preserves effects and clears pending authorization. Ambiguous replay rejections, including stale-input messages, retain the journal for further diagnosis.

## Compatibility and limits

- Old journals containing only a digest remain readable. A found outcome resolves normally. If absent, `LEGACY_JOURNAL_NO_SIGNED_TRANSACTION` identifies the lack of replay data; no replacement transaction is constructed automatically.
- This cannot reconstruct signed bytes for transactions submitted before the change, including the historical partner incident.
- A permanently unavailable RPC, expired transaction or unusable input can still require operator intervention. This is retransmission of the same transaction, not automatic replacement of an unresolved operation.
- The existing same-wallet serialization remains in-process. Do not run multiple daemons sharing one wallet/journal concurrently.
- Preserve the journal path and network/package configuration during restart. Moving a signed pending journal into a different context is rejected before replay.
- Signed transaction records authorize execution. Do not publish journals or include bytes/signatures in logs or public diagnostics. Keep storage and backups private; no private key is stored in the journal.

No Move deployment or new environment setting is required. Existing pending journals must not be deleted just because an RPC cannot find their digest.

## Regression coverage

`npm run test:security` in `node` covers lost submissions, lookup recovery without replay, restart in a fresh process, identical bytes/signature, checkpoint wait failures, legacy journals, transport failures, corrupted authorizations, persisted retry delays, workflow separation and definitive on-chain failure. These are offline tests using real transaction serialization and signatures with mocked RPC responses; they do not submit blockchain transactions.
