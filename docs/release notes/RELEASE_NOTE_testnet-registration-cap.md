# v2.0.15 — Testnet delegated-cap registration correction

Published on testnet on 24 November 2026. Exact IDs and transaction digests:
[deployment.json](../../move/testnet/deployment.json).

Partner upgrade from an existing checkout (valid delegated cap required):

```bash
git pull --ff-only && bash ./update.sh --skip-git --network testnet --no-webview
```

This updates IDs and per-node overrides, preserves cap/private-key/RPC settings,
rebuilds and recreates the node container, re-registers automatically, and checks
readiness. Host npm is unnecessary for Docker upgrades. Failures return nonzero.

## Problem and corrected behavior

The testnet Move package exposed `systemState::register_oracle_node_dev` and
allowed callers without a delegated cap to enter the node registry. Task
assignment and oracle quorum membership relied on that registry. Two such
registrations were confirmed; participation in task consensus was not established
by that investigation.

The testnet dev entry now aborts unconditionally. Only registration with a typed
delegated cap, node sender and committee validator can populate the registry.
Registration also binds the supplied registry to its State. The private writer
no longer accepts a dev-mode override. Separate devnet registration is preserved.

The node rejects dev mode on testnet/mainnet and missing/unknown networks, and
refuses mixed package/State/registry IDs instead of deriving an older package
silently from State. The legacy dev helper uses the State's linked registry.

A second unguarded entry, `append_result_for_testing`, is now test-only in both
task packages and is absent from production bytecode.

## Deployment and partner action

Source changes are not an on-chain remediation. Freshly publish system, tasks
and scheduler, using new objects and reusing the validator-caps package. Do not
upgrade the existing registry in place. Old packages remain callable; new types
isolate their records and tasks from the new system.

Partners must update the complete package/object configuration, preserve their
wallet keys and compatible delegated caps, restart and re-register. Task owners
must inventory/retire old tasks and recreate required tasks; suspension alone
does not close executions already in progress. See
[the deployment and partner runbook](../TESTNET_REGISTRATION_MIGRATION.md).

The nine previously approved templates and prices are seeded at private module
initialization from a checked-in on-chain snapshot; subsequent changes retain
the existing proposal/approval workflow.

Deployment scripts now run registration tests, reject dev-enabled testnet source,
validate publication reports, and preserve cap settings while updating all
duplicate environment keys. `update_testnet_envs.sh --check` is read-only.

## Verification

- Five Move regression tests pass: authorized registration/update, dev registration
  denial for self/another address, sender mismatch and cap reuse on a second node.
- Production testnet tasks/scheduler and devnet tasks builds pass. Existing Move
  lint warnings about transfers, unused parameters and trailing semicolons remain.
- Eight offline migration tests pass, including mixed/partial/ambiguous reports,
  duplicate keys, node overrides, custom RPC and cap preservation. Four unattended
  updater tests cover success, readiness failure and invalid/empty service inventory.
- Node TypeScript build and all 40 node tests pass with a clean lockfile install.
  The existing workspace dependency tree had form-data 4.0.5 despite a lockfile
  pin of 4.0.6; use `npm ci` or rebuild containers rather than reusing that tree.
- Bash syntax checks and `git diff --check` pass.

All three publication transactions succeeded. Read-only on-chain inspection
verified dev registration abort code 7, legacy-function/new-registry type rejection,
absence of the production test helper and equality of all nine template definitions.
No positive partner registration or task consensus test is claimed: no testnet
validator/delegated cap is available to the maintainer for that test.
Registration validates authorization at admission, not cap ownership on every
vote. The pre-existing certificate path checks quorum/membership but does not
cryptographically verify multisig bytes on-chain; that separate issue remains
outside this registration correction.
