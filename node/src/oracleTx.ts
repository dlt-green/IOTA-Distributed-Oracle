// Copyright (c) 2026 Stefano Della Valle
// SPDX-License-Identifier: LicenseRef-Proprietary

import type { IotaClient } from "@iota/iota-sdk/client";
import { Transaction } from "@iota/iota-sdk/transactions";
import { Ed25519Keypair } from "@iota/iota-sdk/keypairs/ed25519";

import { bcsVecU8, bcsAddress, bcsVecU64, bcsU64 } from "./bcs";
import { envByNetwork } from "./config/env";
import { resolveNodeRegistryId } from "./services/nodeRegistry";
import { readRegisteredOracleNodeByAddr } from "./services/schedulerReader";
import { loadPersistedAcceptedTemplateIds, savePersistedAcceptedTemplateIds } from "./templateState";
import { signAndExecuteWithLockRetry } from "./txRetry.js";
import { resolveRegisterMode, validateRegistrationState } from "./registrationPolicy.js";

function mustEnv(key: string): string {
  const v = process.env[key]?.trim();
  if (!v) throw new Error(`Missing env: ${key}`);
  return v;
}

function optEnv(key: string): string | undefined {
  const v = process.env[key]?.trim();
  return v || undefined;
}

function optEnvByNetwork(baseKey: string): string | undefined {
  return envByNetwork(baseKey) || optEnv(baseKey);
}

function getSystemPackageId(): string {
  return (
    envByNetwork("ORACLE_SYSTEM_PACKAGE_ID") ||
    envByNetwork("ORACLE_PACKAGE_ID") ||
    mustEnv("ORACLE_PACKAGE_ID")
  );
}

function getStateId(): string {
  return (
    envByNetwork("ORACLE_STATE_ID") ||
    envByNetwork("ORACLE_STATUS_ID") ||
    envByNetwork("ORACLE_SYSTEM_STATE_ID") ||
    mustEnv("ORACLE_STATE_ID")
  );
}


function getClockId(): string {
  return (envByNetwork("IOTA_CLOCK_ID") || "0x6").trim() || "0x6";
}

function gasBudget(envKey: string, def: number): number {
  const raw = process.env[envKey]?.trim();
  if (!raw) return def;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`Invalid ${envKey}: ${raw}`);
  return Math.floor(n);
}

function txFailureReason(tx: any): string | null {
  const status = tx?.effects?.status;
  if (!status) return null;
  if (typeof status === "string") {
    return status.toLowerCase() === "success" ? null : status;
  }
  const s = String(status?.status ?? "").toLowerCase();
  if (!s || s === "success") return null;
  return String(status?.error ?? status?.message ?? JSON.stringify(status));
}

async function assertTxSuccess(client: IotaClient, digest: string, label: string, withEvents = false): Promise<void> {
  const finalTx: any = await client.waitForTransaction({
    digest,
    options: withEvents ? { showEffects: true, showEvents: true } : { showEffects: true },
  } as any);
  const reason = txFailureReason(finalTx);
  if (reason) {
    throw new Error(`${label} failed on-chain: ${reason}`);
  }
}

async function findOwnedDelegatedCapId(
  client: IotaClient,
  owner: string,
  expectedType?: string | null,
): Promise<string | null> {
  let cursor: string | null | undefined = null;
  const found: string[] = [];

  for (;;) {
    const page: any = await client.getOwnedObjects({
      owner,
      cursor,
      limit: 50,
      options: { showType: true },
    });

    for (const item of page?.data ?? []) {
      const objectId = String(item?.data?.objectId ?? item?.objectId ?? "").trim();
      const typ = String(item?.data?.type ?? item?.type ?? "").trim();
      if (!objectId || !typ) continue;
      const isDelegatedCap = typ.endsWith("::DelegatedControllerCap");
      const matchesExpected = !expectedType || typ.toLowerCase() === expectedType.toLowerCase();
      if (isDelegatedCap && matchesExpected) {
        found.push(objectId);
      }
    }

    if (!page?.hasNextPage || !page?.nextCursor) break;
    cursor = page.nextCursor;
  }

  if (found.length === 0) return null;
  found.sort();
  return found[0]!;
}

function unwrapNormalizedType(type: any): any {
  let current = type;
  while (current && typeof current === "object") {
    if (current.Reference) {
      current = current.Reference;
      continue;
    }
    if (current.MutableReference) {
      current = current.MutableReference;
      continue;
    }
    break;
  }
  return current;
}

function normalizedStructTag(type: any): string | null {
  const unwrapped = unwrapNormalizedType(type);
  const s = unwrapped?.Struct;
  const address = String(s?.address ?? "").trim().toLowerCase();
  const module = String(s?.module ?? "").trim();
  const name = String(s?.name ?? "").trim();
  if (!address || !module || !name) return null;
  return `${address}::${module}::${name}`;
}

async function expectedDelegatedCapType(client: IotaClient, systemPkg: string): Promise<string | null> {
  const getNormalizedMoveFunction = (client as any)?.getNormalizedMoveFunction;
  if (typeof getNormalizedMoveFunction !== "function") return null;
  try {
    const normalized: any = await getNormalizedMoveFunction.call(client, {
      package: systemPkg,
      module: "systemState",
      function: "register_oracle_node",
    });
    return normalizedStructTag(normalized?.parameters?.[3]);
  } catch {
    return null;
  }
}

async function readObjectTypeAndOwner(
  client: IotaClient,
  objectId: string,
): Promise<{ type: string; ownerAddress: string | null }> {
  const obj: any = await client.getObject({
    id: objectId,
    options: { showType: true, showOwner: true },
  });
  const type = String(obj?.data?.type ?? "");
  const ownerRaw: any = obj?.data?.owner;
  const ownerAddress =
    typeof ownerRaw?.AddressOwner === "string"
      ? String(ownerRaw.AddressOwner).toLowerCase()
      : null;
  return { type, ownerAddress };
}

export async function registerOracleNode(opts: {
  client: IotaClient;
  oracleKeypair: Ed25519Keypair;
  oracleAddr: string;
  oraclePubkeyRaw32: Uint8Array;
  nodeId?: string;
  acceptedTemplateIds?: number[];
}): Promise<string> {
  const { client, oracleKeypair, oracleAddr, oraclePubkeyRaw32 } = opts;
  const mode = resolveRegisterMode();
  if (mode === "off") return "";
  const stateId = getStateId();
  const pkg = getSystemPackageId();
  const nodeRegistryId = await validateRegistrationState(client, stateId, pkg, envByNetwork("ORACLE_NODE_REGISTRY_ID"));
  const currentNode = await readRegisteredOracleNodeByAddr(client, oracleAddr, stateId);
  const persistedAcceptedTemplateIds = opts.nodeId ? loadPersistedAcceptedTemplateIds(opts.nodeId) : [];
  const effectiveAcceptedTemplateIds = (
    opts.acceptedTemplateIds != null
      ? opts.acceptedTemplateIds
      : currentNode?.acceptedTemplateIds ?? persistedAcceptedTemplateIds
  )
    .map((n) => Math.floor(Number(n)))
    .filter((n) => Number.isFinite(n) && n >= 0);

  if (mode === "prod") {
    const signer = oracleKeypair;
    const signerAddress = signer.getPublicKey().toIotaAddress().toLowerCase();
    const delegatedCapTypeMarker = "::DelegatedControllerCap";
    const expectedCapType =
      (await expectedDelegatedCapType(client, pkg)) ??
      (envByNetwork("ORACLE_VALIDATOR_CAPS_PACKAGE_ID")
        ? `${envByNetwork("ORACLE_VALIDATOR_CAPS_PACKAGE_ID")}::validator_caps::DelegatedControllerCap`
        : `${pkg}::systemState::DelegatedControllerCap`);

    let delegatedCapId = optEnvByNetwork("DELEGATED_CONTROLLER_CAP_ID");

    if (!delegatedCapId) {
      delegatedCapId = (await findOwnedDelegatedCapId(client, signerAddress, expectedCapType)) ?? undefined;
    }
    if (!delegatedCapId) {
      throw new Error(
        `Prod registration requires DelegatedControllerCap owned by oracle signer ${signerAddress}. Set DELEGATED_CONTROLLER_CAP_ID or use a signer that owns one.`,
      );
    }

    const capInfo = await readObjectTypeAndOwner(client, delegatedCapId);
    if (!capInfo.type.includes(delegatedCapTypeMarker)) {
      throw new Error(
        `Object ${delegatedCapId} is not DelegatedControllerCap (type=${capInfo.type || "unknown"}).`,
      );
    }
    if (expectedCapType && capInfo.type.toLowerCase() !== expectedCapType.toLowerCase()) {
      throw new Error(
        `DelegatedControllerCap type mismatch: got ${capInfo.type}, expected ${expectedCapType}. Mint/use a delegated cap from ORACLE_VALIDATOR_CAPS_PACKAGE_ID or from the package referenced by register_oracle_node.`,
      );
    }
    if (expectedCapType && !expectedCapType.endsWith(delegatedCapTypeMarker)) {
      throw new Error(
        `register_oracle_node expects ${expectedCapType}, which is not a DelegatedControllerCap type.`,
      );
    }
    if (capInfo.ownerAddress && capInfo.ownerAddress !== signerAddress) {
      const autoOwnedCapId = await findOwnedDelegatedCapId(client, signerAddress, expectedCapType);
      if (autoOwnedCapId && autoOwnedCapId !== delegatedCapId) {
        delegatedCapId = autoOwnedCapId;
      } else {
        throw new Error(
          `DelegatedControllerCap ${delegatedCapId} is owned by ${capInfo.ownerAddress}, but oracle signer is ${signerAddress}.`,
        );
      }
    }

    const systemId = (envByNetwork("IOTA_SYSTEM_STATE_ID") ?? "0x5").trim() || "0x5";

    const res = await signAndExecuteWithLockRetry({
      client,
      signer,
      transactionFactory: () => {
        const tx = new Transaction();
        tx.setGasBudget(gasBudget("GAS_BUDGET_REGISTER", gasBudget("GAS_BUDGET", 30_000_000)));
        tx.moveCall({
          target: `${pkg}::systemState::register_oracle_node`,
          arguments: [
            tx.object(nodeRegistryId),
            tx.object(stateId),
            tx.object(systemId),
            tx.object(delegatedCapId),
            tx.pure(bcsAddress(oracleAddr)),
            tx.pure(bcsVecU8(oraclePubkeyRaw32)),
            tx.pure(bcsVecU64(effectiveAcceptedTemplateIds)),
          ],
        });
        return tx;
      },
      options: { showEffects: true, showObjectChanges: true },
      label: "register_oracle_node",
      maxAttempts: 1,
    });
    const immediateReason = txFailureReason(res);
    if (immediateReason) {
      throw new Error(`register_oracle_node failed on-chain: ${immediateReason}`);
    }
    await assertTxSuccess(client, String(res.digest), "register_oracle_node");
    if (opts.nodeId) savePersistedAcceptedTemplateIds(opts.nodeId, effectiveAcceptedTemplateIds);
    return res.digest as string;
  }

  const res = await signAndExecuteWithLockRetry({
    client,
    signer: oracleKeypair,
    transactionFactory: () => {
      const tx = new Transaction();
      tx.setGasBudget(gasBudget("GAS_BUDGET_REGISTER", gasBudget("GAS_BUDGET", 20_000_000)));
      tx.moveCall({
        target: `${pkg}::systemState::register_oracle_node_dev`,
        arguments: [
          tx.object(nodeRegistryId),
          tx.pure(bcsAddress(oracleAddr)),
          tx.pure(bcsVecU8(oraclePubkeyRaw32)),
          tx.pure(bcsVecU64(effectiveAcceptedTemplateIds)),
        ],
      });
      return tx;
    },
    options: { showEffects: true, showObjectChanges: true },
    label: "register_oracle_node_dev",
    maxAttempts: 1,
  });
  const immediateReason = txFailureReason(res);
  if (immediateReason) {
    throw new Error(`register_oracle_node_dev failed on-chain: ${immediateReason}`);
  }
  await assertTxSuccess(client, String(res.digest), "register_oracle_node_dev");
  if (opts.nodeId) savePersistedAcceptedTemplateIds(opts.nodeId, effectiveAcceptedTemplateIds);
  return res.digest as string;
}

export async function unregisterOracleNode(opts: { client: IotaClient; keypair: Ed25519Keypair }): Promise<string> {
  const { client, keypair } = opts;
  const pkg = getSystemPackageId();
  const stateId = getStateId();
  const nodeRegistryId = await resolveNodeRegistryId(client, stateId);

  const res = await signAndExecuteWithLockRetry({
    client,
    signer: keypair,
    transactionFactory: () => {
      const tx = new Transaction();
      tx.setGasBudget(gasBudget("GAS_BUDGET_UNREGISTER", gasBudget("GAS_BUDGET", 20_000_000)));
      tx.moveCall({
        target: `${pkg}::systemState::unregister_oracle_node`,
        arguments: [tx.object(nodeRegistryId)],
      });
      return tx;
    },
    options: { showEffects: true, showObjectChanges: true },
    label: "unregister_oracle_node",
    maxAttempts: 1,
  });
  const immediateReason = txFailureReason(res);
  if (immediateReason) {
    throw new Error(`unregister_oracle_node failed on-chain: ${immediateReason}`);
  }
  await assertTxSuccess(client, String(res.digest), "unregister_oracle_node");
  return res.digest as string;
}


export async function approveTaskTemplateProposal(opts: {
  client: IotaClient;
  keypair: Ed25519Keypair;
  proposalId?: number;
  expectedTemplateId?: number;
}): Promise<string> {
  const { client, keypair, proposalId, expectedTemplateId } = opts;
  const pkg = getSystemPackageId();
  const stateId = getStateId();
  const nodeRegistryId = await resolveNodeRegistryId(client, stateId);
  const clockId = getClockId();
  const resolvedProposalId = await resolvePendingTemplateProposalId(client, stateId, {
    proposalId,
    expectedTemplateId,
  });

  const res = await signAndExecuteWithLockRetry({
    client,
    signer: keypair,
    transactionFactory: () => {
      const tx = new Transaction();
      tx.setGasBudget(gasBudget("GAS_BUDGET_TEMPLATE_PROPOSAL_APPROVE", gasBudget("GAS_BUDGET", 20_000_000)));
      tx.moveCall({
        target: `${pkg}::systemState::approve_task_template_proposal`,
        arguments: [
          tx.object(nodeRegistryId),
          tx.object(stateId),
          tx.object(clockId),
          tx.pure(bcsU64(resolvedProposalId)),
        ],
      });
      return tx;
    },
    options: { showEffects: true, showEvents: true, showObjectChanges: true },
    label: "approve_task_template_proposal",
  });
  const immediateReason = txFailureReason(res);
  if (immediateReason) {
    throw new Error(`approve_task_template_proposal failed on-chain: ${immediateReason}`);
  }
  await assertTxSuccess(client, String(res.digest), "approve_task_template_proposal", true);
  return res.digest as string;
}

type PendingTemplateProposal = {
  proposalId: number;
  templateId: number;
  kind: number;
  approvals: number;
  electorateSize: number;
};

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function extractFields(value: unknown): Record<string, unknown> | null {
  const record = asRecord(value);
  if (!record) return null;
  const fields = asRecord(record.fields);
  if (fields) return fields;
  const content = asRecord(record.content);
  if (content) return extractFields(content);
  const nestedValue = asRecord(record.value);
  if (nestedValue) return nestedValue;
  return null;
}

function toNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.floor(value);
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "string") {
    const n = Number(value);
    return Number.isFinite(n) ? Math.floor(n) : null;
  }
  const record = asRecord(value);
  if (!record) return null;
  return toNumber(record.value);
}

function toArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  const record = asRecord(value);
  if (!record) return [];
  for (const key of ["items", "contents", "vec", "value"]) {
    const nested = record[key];
    if (Array.isArray(nested)) return nested;
  }
  return [];
}

function parsePendingTemplateProposals(stateFields: Record<string, unknown>): PendingTemplateProposal[] {
  const raw = toArray(stateFields.template_proposals);
  const out: PendingTemplateProposal[] = [];

  for (const item of raw) {
    const fields = extractFields(item) ?? asRecord(item) ?? {};
    const proposalId = toNumber(fields.proposal_id);
    const templateId = toNumber(fields.template_id);
    if (proposalId == null || proposalId <= 0 || templateId == null || templateId <= 0) continue;
    out.push({
      proposalId,
      templateId,
      kind: toNumber(fields.proposal_kind) ?? 0,
      approvals: toNumber(fields.approvals) ?? 0,
      electorateSize: toNumber(fields.electorate_size) ?? 0,
    });
  }

  out.sort((a, b) => a.proposalId - b.proposalId);
  if (out.length > 0) return out;

  // Backward compatibility with single-proposal state layout.
  const active = toNumber(stateFields.template_proposal_active);
  if (active === 1) {
    const proposalId = toNumber(stateFields.template_proposal_id);
    const templateId = toNumber(stateFields.proposed_template_id);
    if (proposalId != null && proposalId > 0 && templateId != null && templateId > 0) {
      out.push({
        proposalId,
        templateId,
        kind: toNumber(stateFields.template_proposal_kind) ?? 0,
        approvals: toNumber(stateFields.template_proposal_approvals) ?? 0,
        electorateSize: toNumber(stateFields.template_proposal_electorate_size) ?? 0,
      });
    }
  }
  return out;
}

async function resolvePendingTemplateProposalId(
  client: IotaClient,
  stateId: string,
  opts: { proposalId?: number; expectedTemplateId?: number },
): Promise<number> {
  const response: any = await client.getObject({
    id: stateId,
    options: { showContent: true },
  });
  const stateFields = extractFields(response?.data?.content);
  if (!stateFields) {
    throw new Error("Cannot parse oracle state object fields");
  }
  const proposals = parsePendingTemplateProposals(stateFields);
  if (proposals.length === 0) {
    throw new Error("No active template proposal on-chain");
  }

  if (opts.proposalId != null) {
    const exact = proposals.find((p) => p.proposalId === opts.proposalId);
    if (!exact) {
      throw new Error(`Pending proposal_id=${opts.proposalId} not found on-chain`);
    }
    if (opts.expectedTemplateId != null && exact.templateId !== opts.expectedTemplateId) {
      throw new Error(
        `Proposal mismatch: proposal_id=${opts.proposalId} has template_id=${exact.templateId}, expected ${opts.expectedTemplateId}`,
      );
    }
    return exact.proposalId;
  }

  if (opts.expectedTemplateId != null) {
    const matches = proposals.filter((p) => p.templateId === opts.expectedTemplateId);
    if (matches.length === 0) {
      throw new Error(`No active template proposal on-chain for template_id=${opts.expectedTemplateId}`);
    }
    if (matches.length > 1) {
      throw new Error(
        `Multiple pending proposals for template_id=${opts.expectedTemplateId}. Pass --proposal-id explicitly.`,
      );
    }
    return matches[0]!.proposalId;
  }

  if (proposals.length > 1) {
    throw new Error(`Multiple pending proposals found (${proposals.length}). Pass --proposal-id or --template-id.`);
  }
  return proposals[0]!.proposalId;
}
