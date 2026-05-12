# Delegated Controller Cap Workflow (Testnet/Devnet)

This guide covers the full end-to-end flow:

1. Prerequisites.
2. Mint a `DelegatedControllerCap` for a node.
3. Update `.env` and verify delegated cap ownership.
4. Register the node on-chain with that cap.
5. Propose task templates (only for Oracle Supervisor).
6. Approve task proposals.
7. Check status.
8. Common signer mistakes and troubleshooting.

Each section includes:

- Local execution (`iota` CLI installed on host)
- Container execution (`docker compose exec oracle-node-1 ...`)

---

## 1) Prerequisites

- Repository checked out and up to date.
- Correct `.env` in `node/`:
  - `IOTA_NETWORK`
  - `ORACLE_SYSTEM_PACKAGE_ID`
  - `ORACLE_TASKS_PACKAGE_ID`
  - `ORACLE_STATE_ID`
  - `CONTROLLER_CAP_ID` (owner is the admin/controller account)
  - `ORACLE_VALIDATOR_CAPS_PACKAGE_ID` (package used to mint delegated caps, required where validator caps are split from the system package)
  - `DELEGATED_CONTROLLER_CAP_ID` (will be filled after mint)
- Validator operation cap id (for minting delegated cap):
  - `UnverifiedValidatorOperationCap` id (example: `0xf21a...`)
- Node address that will own the delegated cap.
- Node address has gas funds for registration and approvals.

---

## 2) Mint Delegated Controller Cap

### 2.1 Local CLI version

Run from `node/`:

```bash
bash ./scripts/create_delegated_controller_cap.sh \
  --network testnet \
  --validator-address <VALIDATOR_ADDRESS> \
  --node-address <NODE_ADDRESS> \
  --validator-cap-id <UNVERIFIED_VALIDATOR_OPERATION_CAP_ID>
```

Notes:

- The script switches env and validator address automatically.
- At the end it prints:
  - `Latest candidate DELEGATED_CONTROLLER_CAP_ID=0x...`

### 2.2 Container version

From repo root:

```bash
docker compose up -d oracle-node-1
docker compose exec oracle-node-1 bash -lc "bash ./scripts/create_delegated_controller_cap.sh \
    --network testnet \
    --validator-address <VALIDATOR_ADDRESS> \
    --node-address <NODE_ADDRESS> \
    --validator-cap-id <UNVERIFIED_VALIDATOR_OPERATION_CAP_ID>"
```

---

## 3) Update `.env` and verify ownership

Set:

```dotenv
DELEGATED_CONTROLLER_CAP_ID=<NEW_DELEGATED_CAP_ID>
```

Verify delegated cap on-chain:

```bash
iota client object <NEW_DELEGATED_CAP_ID> --json
```

Expected:

- type: `...::systemState::DelegatedControllerCap`
- owner: `<NODE_ADDRESS>`
- fields include `validator_address` and `validator_cap_id`

---

## 4) Register node on-chain

Node registration must be signed by the node account (owner of delegated cap), not by validator/controller.

### 4.1 Local CLI version

Switch env and node address:

```bash
iota client switch --env testnet
iota client switch --address <NODE_ADDRESS>
```

Start node:

```bash
docker compose up -d oracle-node-1
docker compose logs -f oracle-node-1
```

Expected log line:

```text
[node 1] registered tx=...
```

### 4.2 Container version

```bash
docker compose up -d oracle-node-1
docker compose exec oracle-node-1 bash -lc "iota client switch --env testnet && iota client switch --address <NODE_ADDRESS>"
docker compose logs -f oracle-node-1
```

---

## 5) Propose task templates (oracle supervisor only)

Template proposal uses `ControllerCap`, so signer must be the owner of `CONTROLLER_CAP_ID` (controller/admin account).

### 5.1 Local CLI version

```bash
iota client switch --env testnet
iota client switch --address <CONTROLLER_CAP_OWNER_ADDRESS>
bash ./scripts/propose_templates_interactive.sh
```

Select `all` (or chosen ids) when prompted.

### 5.2 Container version

```bash
docker compose exec oracle-node-1 bash -lc "iota client switch --env testnet && iota client switch --address <CONTROLLER_CAP_OWNER_ADDRESS> && bash ./scripts/propose_templates_interactive.sh"
```

---

## 6) Approve task proposals (oracle node side)

Approval is done by oracle nodes (registered addresses), not by controller-only address.

### 6.1 Local CLI version

```bash
iota client switch --env testnet
iota client switch --address <NODE_ADDRESS>
bash ./scripts/approve_template_interactive.sh --node 1
```

### 6.2 Container version

```bash
docker compose exec oracle-node-1 bash -lc "iota client switch --env testnet && iota client switch --address <NODE_ADDRESS> && bash ./scripts/approve_template_interactive.sh --node 1"
```

---

## 7) Check status

Approved templates:

```bash
bash ./scripts/list_templates.sh
```

Pending proposals:

```bash
bash ./scripts/list_templates.sh --pending
```

Supported templates for the node:

```bash
bash ./scripts/update_supported_templates.sh --node 1
```

Non-interactive replacement:

```bash
bash ./scripts/update_supported_templates.sh --node 1 --templates 1,2,3,4,5,6,7,8 --yes
```

---

## 8) Common signer mistakes

- Error: `Transaction was not signed by the correct sender`
  - Cause: using object `ControllerCap` or `DelegatedControllerCap` with a different signer than object owner.
  - Fix: switch to the owner address of that object before submitting.

- Node registers but cannot propose templates:
  - This is normal if node address is not owner of `ControllerCap`.
  - Use controller/admin address for propose; use node address for register/approve.

- `Cannot find gas coin for signer`
  - Fund the active signer address with enough IOTA.
