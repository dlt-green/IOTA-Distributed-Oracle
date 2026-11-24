# Testnet delegated-cap registration correction

Status: published on testnet on 24 November 2026 (v2.0.15). The exact IDs and
publication digests are in [deployment.json](../move/testnet/deployment.json).
All three publications succeeded. Read-only chain checks verified the denied
dev entry, old-package/new-registry type rejection and all nine approved templates.
Positive validator registration and task consensus still require a partner test.

## Unattended partner upgrade

From the existing repository checkout, run:

```bash
git pull --ff-only && bash ./update.sh --skip-git --network testnet --no-webview
```

No interactive prompts or manual package-ID edits are required. Existing wallet
keys, delegated cap IDs, accepted-template caches, provider credentials and custom
RPC endpoints are preserved. The script migrates global, TESTNET and node-scoped
IDs, sets testnet registration to prod/automatic, rebuilds/recreates containers,
and waits for node readiness. Docker builds use Node 24 without requiring host npm.
Remove `--no-webview` if this host also runs the Webview. Use the same existing
privileges needed for Docker; the script does not invoke interactive sudo.

An existing valid delegated cap and a funded node wallet remain prerequisites.
Readiness failure returns nonzero after `UPDATE_READY_TIMEOUT` seconds (default
180); it does not silently restore the vulnerable package. No credentials or
capabilities are generated or requested by the updater. Other-network node
overrides are preserved. Custom Compose environment entries that override `.env`
must already be aligned with the supported environment-file deployment.

## What changes

The previous testnet system package exposed `register_oracle_node_dev` without
a network or capability check. A caller could enter the node registry without
a delegated cap. Assignment, scheduling and oracle quorum membership trusted
that registry. Two such registrations were confirmed on 23 November 2026;
this is not evidence that those nodes voted or changed a task result.

In the corrected testnet package the dev entry always aborts with
`EInvalidNetworkMode` (7). The only insertion/update path requires a typed
`validator_caps::DelegatedControllerCap`, the node's signature, a matching
node address and a validator in the IOTA committee. The State must reference
the supplied NodeRegistry. The private writer has no dev-mode bypass.
The separate devnet system package retains cap-free registration.

The `append_result_for_testing` helper is now test-only in both task packages;
it must not be present in production bytecode.

## Required deployment model

**Fresh publish system state, tasks and scheduler; do not upgrade in place.**
New package identities create new State, NodeRegistry, TaskRegistry,
SchedulerQueue and task types. The old registration function cannot accept a
new NodeRegistry, and old Task objects cannot be passed to the new task module.
Do not import old registry rows or old assignments. Every node registers again
through the capability-checked entry.

Reuse the existing validator-caps package. Existing delegated caps remain usable
if their type matches that package, they are owned by the node signer and their
validator is still in the committee. Do not mint replacement caps automatically.

Old packages remain callable on-chain. Publishing new ones does not disable old
tasks, invalidate old results, move balances or transfer task ownership. Stop
old daemons, stop submitting to the old deployment, and have task owners suspend
old scheduled tasks before cutover. Inventory pending executions and balances;
handle retirement/refunds through the supported owner operations. Recreate
required tasks against the new deployment with new IDs and deliberate funding.
Do not silently replay funded tasks or copy old certificates.
Suspending a task stops future scheduling but does not prevent finalization of
an already OPEN/MEDIATION_PENDING execution. Deletion/refund is blocked while
such an execution is live. Resolve or explicitly quarantine these cases before
the final shutdown; do not promise automatic cancellation or fund recovery.

This fix enforces admission at registration. It does not introduce live
cap-ownership/revocation checks on every vote. The existing certificate contract
checks quorum and assigned addresses but does not cryptographically verify the
multisig bytes on-chain; this separate limitation requires its own remediation
and must not be described as resolved by this registration patch.

## Maintainer procedure

1. Coordinate the maintenance window and stop old task submissions/daemons.
   Preserve wallet keys, delegated cap IDs, task inventory and existing runtime
   data. Keep the old IDs for audit, not as a fallback for the new service.
2. Run the regression tests and production builds before publishing:

   ```bash
   iota move test --path move/testnet/oracle_system_state_testnet --skip-fetch-latest-git-deps
   iota move build --path move/testnet/oracle_tasks_testnet --skip-fetch-latest-git-deps
   iota move build --path move/testnet/iota_task_scheduler_testnet --skip-fetch-latest-git-deps
   cd node
   npm ci
   npm run build
   npm run test:security
   cd ..
   ```

3. Publish from the reviewed checkout with the intended funded testnet account:

   ```bash
   TARGET_ENV=testnet DEPLOY_ADDRESS=OID_Groundcontrol \
     bash move/testnet/deploy_testnet_kit.sh
   bash move/testnet/update_testnet_envs.sh --check
   bash move/testnet/update_testnet_envs.sh
   ```

   The deployment script reuses validator caps and freshly publishes the three
   dependent packages. It runs registration tests before publication. If any
   publication fails, stop the cutover: do not distribute a partial set of IDs.
   Verify the dependency linkage on-chain before announcing the kit.
   The updater rejects the known vulnerable package reports, validates required
   report fields, updates duplicate keys and preserves delegated cap settings.
   `--check` validates reports only; it does not modify environment files and is
   not an on-chain deployment attestation.

4. Review the full resulting configuration and distribute one coherent manifest
   of all new package/object IDs. Update the node, client, Webview and external
   integrations, including any task consumers hardcoding the old package or IDs.
   Do not send wallet keys, passwords or provider secrets with the manifest.
5. Re-register authorized nodes. The nine previously approved template
   definitions/prices are installed by private module initialization from the
   reviewed `approved_templates_snapshot.json`; no runtime bootstrap setter exists.
   Future changes still use the existing supervisor proposal and node approval workflow. Use
   `node/scripts/propose_template_from_json.sh`,
   `node/scripts/approve_template_interactive.sh` and
   `node/scripts/list_templates.sh`. Verify template IDs and accepted-template
   lists before recreating tasks or enabling submissions.
6. Rebuild/recreate Webview and node services. Verify the live dashboard reads
   the new registry and that every row has a real delegated cap. Run a small
   authorized task end-to-end (assignment, result, quorum, payment). Verify a
   cap-free dev-entry call against the new package aborts, preferably by dry-run.
   Also dry-run an old-function/new-registry combination and verify type rejection.
   Never use a successful unauthorized registration on the live registry as a test.
7. Check readiness and registration transaction success for each partner before
   reopening submissions. Record the published IDs and transaction digests in
   the release record. Do not claim closure on the old deployment.

## Partner configuration and restart

Keep the node's existing private key and delegated cap. Stop the existing node
using its service manager before replacing configuration. Do not overwrite an
existing `.env` with `.env.example`.

The unattended updater sets the following keys from the published reports, both
generic keys and their `TESTNET_` equivalents. This table is also a reference for
custom deployments outside the supplied Compose procedure:

| Key | Required value |
| --- | --- |
| `ORACLE_SYSTEM_PACKAGE_ID` | New system package |
| `ORACLE_TASKS_PACKAGE_ID` | New tasks package |
| `ORACLE_STATE_ID` | New State |
| `ORACLE_NODE_REGISTRY_ID` | New NodeRegistry |
| `ORACLE_TREASURY_ID` | New OracleTreasury |
| `ORACLE_TASK_REGISTRY_ID` | New TaskRegistry |
| `ORACLE_TASK_SCHEDULER_QUEUE_ID` | New tasks SchedulerQueue |
| `ORACLE_VALIDATOR_CAPS_PACKAGE_ID` | Reused validator-caps package |
| `CONTROLLER_CAP_ID` | New supervisor cap, only for supervisor operations |

Consumers of the separate scheduler package must also use its new package and
object IDs from its publication report; it is distinct from the tasks queue.

Set the network and registration controls explicitly:

```dotenv
IOTA_NETWORK=testnet
REGISTER_MODE=prod
AUTO_REGISTER=true
NODE_1_NETWORK=testnet
NODE_1_REGISTER_MODE=prod
NODE_1_AUTO_REGISTER=true
NODE_1_DELEGATED_CONTROLLER_CAP_ID=<YOUR_EXISTING_VALID_DELEGATED_CAP_ID>
```

Review equivalent `NODE_<id>_*` overrides for every node, network-prefixed values,
Compose environment entries and service-manager environment settings. Update
custom event-type filters containing old package IDs. Preserve supported
template lists and keys; a node should advertise only templates it can execute.

From `node/`, for the supplied Docker Compose deployment:

```bash
docker compose up -d --build --force-recreate oracle-node-1
docker compose logs --tail=100 oracle-node-1
```

For a standalone installation, use `npm ci`, `npm run build`, then restart the
existing service or run `npm run daemon -- --node 1`. Confirm `registered tx=...`
and its successful chain effects, correct validator/cap in the new registry,
accepted templates, and service readiness. A process being up is not proof of
successful registration. `npm run test -- ...` executes a task locally only.

`REGISTER_MODE=dev` on testnet/mainnet now fails explicitly. Missing/unknown
networks also fail registration. Mixed package/State/registry configurations
fail instead of falling back to the old package. This check intentionally
supports the fresh-publication procedure, not an upgrade-in-place package ID
whose type origin differs. Do not bypass it to suppress a migration error.

If the cap is missing, check its exact type
`<VALIDATOR_CAPS_PACKAGE>::validator_caps::DelegatedControllerCap`, owner and
validator committee membership. The node may autodetect a matching owned cap
when no cap ID is configured. Do not substitute the registry ID or a supervisor
ControllerCap, and do not switch to dev mode.
