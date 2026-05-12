# IOTA Oracle Node - CLI Guide

## Overview

This Oracle node supports:

1. **On-chain daemon** for event-driven task processing
2. **CLI** for operational admin commands

## Important behavior

`STORAGE` tasks are **IPFS-only**. Node manager need to configure a IPFS node and api key to support STORAGE task.

## Install

```bash
npm install
cp .env.example .env
npm run build
```

## Start

```bash
npm run daemon -- --node 1
```

Registration rule:
- if `IOTA_NETWORK` is not `dev`/`devnet` (or `local`/`localnet`), node registration is forced to `systemState::register_oracle_node` and requires a `systemState::DelegatedControllerCap` + signer key.
- in prod mode, if `DELEGATED_CONTROLLER_CAP_ID` is not set, node tries to auto-detect an owned `systemState::DelegatedControllerCap` from the signer address.

## Test current node configuration

Before starting the daemon, you can run a local execution test against the current `.env`:

```bash
npm run test -- src/tasks/examples/task_weather.json --node 1
```

For storage configuration checks:

```bash
npm run test -- src/tasks/examples/task_IPFS_STORE1.json --node 1
```

The test runner validates:

- node key loading and derived address
- accepted templates from `ORACLE_ACCEPTED_TEMPLATE_IDS`
- task handler availability
- template policy constraints
- local execution of the task handler
- `STORAGE`-specific IPFS env visibility

It is a configuration and local execution check only.
It does not submit transactions and does not verify registration, assignment, quorum, publish, or final on-chain state.

## CLI commands

### Accept template proposal

```bash
npm run cli -- accept-template-proposal --node 1
npm run cli -- accept-template-proposal --node 1 --proposal-id 12
npm run cli -- accept-template-proposal --node 1 --template-id 4
```

If multiple proposals are pending, pass `--proposal-id` (or a unique `--template-id`).

### Update accepted templates for node

```bash
npm run cli -- set-accepted-templates --node 1 --templates 1,2,3,4,5,6,7,8
```

This **replaces** `accepted_template_ids` on-chain.

## Node Manager scripts

### Approve proposal by id/template

```bash
bash ./scripts/approve_template_interactive.sh --node 1
```

### Update node supported templates

```bash
bash ./scripts/update_supported_templates.sh --node 1
bash ./scripts/update_supported_templates.sh --node 1 --templates 1,2,3,4,5,6,7,8 --yes
```

`update_supported_templates.sh` computes a replacement list, calls `set-accepted-templates`, and updates `NODE_<id>_ORACLE_ACCEPTED_TEMPLATE_IDS`, `ORACLE_ACCEPTED_TEMPLATE_IDS`, and the network-specific accepted-template key in `.env` (default `./.env`, override with `--env-file`).

### List approved templates (and pending approvals)

```bash
bash ./scripts/list_templates.sh
```

Include pending proposals with current approvals:

```bash
bash ./scripts/list_templates.sh --pending
```

Show only pending proposal details:

```bash
bash ./scripts/list_templates.sh --pending-only
```

JSON output:

```bash
bash ./scripts/list_templates.sh --pending --json
```

## IPFS requirements for STORAGE

`STORAGE` task execution requires:

```env
IPFS_ENABLED=true
IPFS_API_URL=...
```

Plus valid IPFS auth.

## Troubleshooting

### `accept-template-proposal` fails

Check:

- `IOTA_RPC_URL`
- `ORACLE_SYSTEM_PACKAGE_ID`
- `ORACLE_STATE_ID`
- node wallet gas balance
- active approvable proposal exists on-chain

### STORAGE task fails with IPFS error

Check:

- `IPFS_ENABLED=true`
- `IPFS_API_URL` reachable
- credentials are valid
- file size is within configured limits
