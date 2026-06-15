// Copyright (c) 2026 Stefano Della Valle
// SPDX-License-Identifier: LicenseRef-Proprietary

import type { IotaClient } from "@iota/iota-sdk/client";

import { getStateId } from "../config/env";
import type { NodeContext } from "../nodeContext";
import { optBool, optInt } from "../nodeConfig";
import { registerOracleNode } from "../oracleTx";
import { getIpfsConfig, uploadBytesToIpfs, deleteCidFromIpfs } from "../ipfs";
import { callLlmJson } from "../tasks/utils/llm";
import { readRegisteredOracleNodeByAddr } from "./schedulerReader";
import { getAnyMoveFields, getMoveFields } from "../utils/move";
import { sleep } from "../utils/sleep";
import type { CapabilityHealthRuntimeState } from "../monitor";

type TaskTemplateSummary = {
  templateId: number;
  taskType: string;
  allowStorage: boolean;
};

type CapabilityName = "LLM" | "IPFS";

type TemplateRemovalResult = {
  removed: number[];
  txDigest: string | null;
};

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
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

function toNum(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) return Math.floor(value);
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "string") {
    const n = Number(value);
    return Number.isFinite(n) ? Math.floor(n) : 0;
  }
  const record = asRecord(value);
  if (!record) return 0;
  return toNum(record.value);
}

function toTemplateId(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.floor(value);
  if (typeof value === "bigint") return Number(value);
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return null;
    const n = Number(trimmed);
    return Number.isFinite(n) ? Math.floor(n) : null;
  }
  const record = asRecord(value);
  if (!record || !("value" in record)) return null;
  return toTemplateId(record.value);
}

function toStr(value: unknown): string {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "bigint") return String(value);
  if (Array.isArray(value) && value.every((x) => typeof x === "number")) {
    try {
      return new TextDecoder().decode(Uint8Array.from(value as number[]));
    } catch {
      return "";
    }
  }
  const record = asRecord(value);
  if (!record) return "";
  if (typeof record.value === "string") return record.value;
  if (Array.isArray(record.bytes) && record.bytes.every((x) => typeof x === "number")) return toStr(record.bytes);
  if (record.fields) return toStr((record.fields as Record<string, unknown>).value ?? record.fields);
  return "";
}

function templateMatchesLlm(template: TaskTemplateSummary): boolean {
  return template.taskType.toUpperCase().includes("LLM");
}

function templateMatchesIpfs(template: TaskTemplateSummary): boolean {
  const taskType = template.taskType.toUpperCase();
  return taskType.includes("IPFS") || taskType.includes("STORAGE") || template.allowStorage;
}

async function listTaskTemplates(client: IotaClient): Promise<TaskTemplateSummary[]> {
  const stateId = getStateId();
  const out: TaskTemplateSummary[] = [];
  let cursor: string | null | undefined = null;

  for (;;) {
    const page: any = await client.getDynamicFields({ parentId: stateId, cursor, limit: 50 });
    for (const item of page?.data ?? []) {
      const nameType = String(item?.name?.type ?? "");
      if (!nameType.includes("TaskTemplateKey")) continue;
      const objectId = String(item?.objectId ?? "").trim();
      if (!objectId) continue;

      const obj: any = await client.getObject({ id: objectId, options: { showContent: true } });
      const outerFields = getMoveFields(obj);
      const valueFields = getAnyMoveFields(outerFields.value);
      const templateId = toTemplateId(valueFields.template_id);
      if (templateId == null || templateId < 0) continue;

      out.push({
        templateId,
        taskType: toStr(valueFields.task_type),
        allowStorage: toNum(valueFields.allow_storage) !== 0,
      });
    }

    if (!page?.hasNextPage || !page?.nextCursor) break;
    cursor = page.nextCursor;
  }

  return out.sort((a, b) => a.templateId - b.templateId);
}

async function testLlmConfig(): Promise<void> {
  await callLlmJson({
    taskName: "LLM_HEALTH_CHECK",
    prompt: 'Return exactly this JSON: {"ok":true}',
    schema: {
      type: "object",
      additionalProperties: false,
      required: ["ok"],
      properties: {
        ok: { type: "boolean" },
      },
    },
    llmConfig: {
      temperature: 0,
      top_p: 1,
      max_output_tokens: 32,
      timeoutMs: optInt("LLM_HEALTH_TIMEOUT_MS", 20_000),
    },
    normalization: { canonical: true, dropNulls: false, sortArrays: false },
  });
}

async function testIpfsConfig(): Promise<void> {
  const cfg = getIpfsConfig();
  if (!cfg.enabled) throw new Error("IPFS is disabled");

  const uploaded = await uploadBytesToIpfs({
    bytes: new TextEncoder().encode(`oracle-ipfs-healthcheck:${Date.now()}`),
    fileName: "oracle-ipfs-healthcheck.txt",
    mimeType: "text/plain",
  });

  await deleteCidFromIpfs({ cid: uploaded.cid, allowMissing: true }).catch((error) => {
    console.warn(`[template-health] IPFS cleanup failed cid=${uploaded.cid}: ${String((error as any)?.message ?? error)}`);
  });
}

async function removeTemplateSupport(
  ctx: NodeContext,
  reason: CapabilityName,
  failedError: string,
): Promise<TemplateRemovalResult> {
  const currentNode = await readRegisteredOracleNodeByAddr(ctx.client, ctx.myAddr);
  const accepted = currentNode?.acceptedTemplateIds ?? ctx.acceptedTemplateIds;
  const templates = await listTaskTemplates(ctx.client);
  const blockedIds = new Set(
    templates
      .filter((template) => reason === "LLM" ? templateMatchesLlm(template) : templateMatchesIpfs(template))
      .map((template) => template.templateId),
  );

  const nextAccepted = accepted.filter((templateId) => !blockedIds.has(templateId));
  const removed = accepted.filter((templateId) => blockedIds.has(templateId));
  if (removed.length === 0) {
    console.warn(`[template-health] ${reason} check failed but no accepted ${reason} templates are enabled: ${failedError}`);
    return { removed: [], txDigest: null };
  }

  const digest = await registerOracleNode({
    client: ctx.client,
    oracleKeypair: ctx.identity.keypair,
    oracleAddr: ctx.identity.address,
    oraclePubkeyRaw32: ctx.identity.publicKeyBytes,
    nodeId: ctx.nodeId,
    acceptedTemplateIds: nextAccepted,
  });

  ctx.acceptedTemplateIds = nextAccepted;
  console.warn(
    `[template-health] removed ${reason} template support templates=${removed.join(",")} remaining=${nextAccepted.join(",") || "<none>"} tx=${digest || "<none>"} reason=${failedError}`,
  );
  return { removed, txDigest: digest ?? null };
}

async function runTemplateHealthCheck(ctx: NodeContext, healthState: CapabilityHealthRuntimeState): Promise<void> {
  const checks: Array<{ name: CapabilityName; enabled: boolean; run: () => Promise<void> }> = [
    { name: "LLM", enabled: optBool("LLM_HEALTH_CHECK_ENABLED", true), run: testLlmConfig },
    { name: "IPFS", enabled: optBool("IPFS_HEALTH_CHECK_ENABLED", true), run: testIpfsConfig },
  ];

  healthState.running = true;
  healthState.lastStartedAtMs = Date.now();

  for (const check of checks) {
    const checkState = healthState.checks[check.name];
    checkState.enabled = check.enabled;

    if (!check.enabled) {
      checkState.status = "disabled";
      continue;
    }

    const startedAtMs = Date.now();
    checkState.status = "running";
    checkState.lastStartedAtMs = startedAtMs;
    checkState.lastCheckedAtMs = startedAtMs;
    checkState.templatesRemoved = [];
    checkState.lastRemovalTxDigest = null;
    checkState.lastRemovalError = null;

    try {
      await check.run();
      const completedAtMs = Date.now();
      checkState.status = "ok";
      checkState.lastCheckedAtMs = completedAtMs;
      checkState.lastOkAtMs = completedAtMs;
      checkState.lastError = null;
      checkState.lastRemovalError = null;
      console.log(`[template-health] ${check.name} check ok`);
    } catch (error: any) {
      const failedAtMs = Date.now();
      const msg = String(error?.message ?? error);
      checkState.status = "failed";
      checkState.lastCheckedAtMs = failedAtMs;
      checkState.lastErrorAtMs = failedAtMs;
      checkState.lastError = msg;
      console.warn(`[template-health] ${check.name} check failed: ${msg}`);
      await removeTemplateSupport(ctx, check.name, msg).then((result) => {
        checkState.templatesRemoved = result.removed;
        checkState.lastRemovalTxDigest = result.txDigest;
      }).catch((removeError: any) => {
        const removeMsg = String(removeError?.message ?? removeError);
        checkState.lastRemovalError = removeMsg;
        console.warn(
          `[template-health] failed to remove ${check.name} template support: ${removeMsg}`,
        );
      });
    }
  }

  healthState.running = false;
  healthState.lastCompletedAtMs = Date.now();
}

export function startTemplateHealthWorker(ctx: NodeContext, healthState: CapabilityHealthRuntimeState): void {
  if (!optBool("TEMPLATE_HEALTH_WORKER_ENABLED", true)) {
    healthState.workerEnabled = false;
    healthState.checks.LLM.status = "disabled";
    healthState.checks.IPFS.status = "disabled";
    console.log(`[template-health] worker disabled`);
    return;
  }

  const intervalMs = Math.max(60_000, optInt("TEMPLATE_HEALTH_INTERVAL_MS", 5 * 60_000));
  const initialDelayMs = Math.max(0, optInt("TEMPLATE_HEALTH_INITIAL_DELAY_MS", 30_000));
  let running = false;
  healthState.workerEnabled = true;
  healthState.intervalMs = intervalMs;
  healthState.initialDelayMs = initialDelayMs;

  const runOnce = async () => {
    if (running) return;
    running = true;
    try {
      await runTemplateHealthCheck(ctx, healthState);
    } finally {
      running = false;
      healthState.running = false;
    }
  };

  console.log(`[template-health] worker enabled interval_ms=${intervalMs} initial_delay_ms=${initialDelayMs}`);
  setTimeout(() => void runOnce(), initialDelayMs);
  setInterval(() => void runOnce(), intervalMs);
}
