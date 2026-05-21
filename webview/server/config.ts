// Copyright (c) 2026 Stefano Della Valle
// SPDX-License-Identifier: LicenseRef-Proprietary

import "dotenv/config";
import path from "node:path";

export type OracleNetwork = "mainnet" | "testnet" | "devnet";
const ALL_NETWORKS: OracleNetwork[] = ["mainnet", "testnet", "devnet"];

function toNumber(value: string | undefined, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function toList(value: string | undefined): string[] {
  return String(value ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function envAny(...names: string[]): string {
  for (const name of names) {
    const value = process.env[name]?.trim();
    if (value) return value;
  }
  return "";
}

function normalizeNetwork(value: string | undefined): OracleNetwork {
  const raw = String(value ?? "").trim().toLowerCase();
  if (raw === "dev" || raw === "devnet") return "devnet";
  if (raw === "test" || raw === "testnet") return "testnet";
  return "mainnet";
}

function networkPrefix(network: OracleNetwork): string {
  return network.toUpperCase();
}

function hasScopedNetworkConfig(key: string): boolean {
  return ALL_NETWORKS.some((network) =>
    Object.prototype.hasOwnProperty.call(process.env, `${networkPrefix(network)}_${key}`),
  );
}

function hasRuntimeConfig(network: OracleNetwork): boolean {
  const tasksPackageId = pickNetworkValue(network, "ORACLE_TASKS_PACKAGE_ID");
  const systemPackageId = pickNetworkValue(network, "ORACLE_SYSTEM_PACKAGE_ID");
  const stateId =
    pickNetworkValue(network, "ORACLE_STATE_ID") ||
    pickNetworkValue(network, "ORACLE_SYSTEM_STATE_ID") ||
    pickNetworkValue(network, "ORACLE_STATUS_ID");
  return Boolean(tasksPackageId && systemPackageId && stateId);
}

const rootDir = process.cwd();
const clientDir = path.resolve(rootDir, process.env.ORACLE_CLIENT_DIR ?? "../iota_oracle_client");
const examplesDirRaw = process.env.ORACLE_EXAMPLES_DIR?.trim() || process.env.ORACLE_CLIENT_EXAMPLES_DIR?.trim() || "examples";
const examplesDir = path.resolve(rootDir, examplesDirRaw);
const defaultEulaSourceUrl =
  "https://raw.githubusercontent.com/sdellava/IOTA-Distributed-Oracole/asset/EULA.md";

const supportedNetworks = (toList(process.env.VITE_SUPPORTED_NETWORKS) as OracleNetwork[])
  .map((n) => normalizeNetwork(n))
  .filter((n, i, arr) => arr.indexOf(n) === i);
if (supportedNetworks.length === 0) supportedNetworks.push("mainnet", "testnet", "devnet");

const envPreferred = normalizeNetwork(process.env.IOTA_NETWORK);
const configuredDefault = normalizeNetwork(
  process.env.WEBVIEW_DEFAULT_NETWORK ?? process.env.VITE_DEFAULT_NETWORK ?? "mainnet",
);
const preferredOrder = [envPreferred, configuredDefault].filter(
  (network, index, arr): network is OracleNetwork => Boolean(network) && arr.indexOf(network) === index,
);
const firstConfiguredNetwork = supportedNetworks.find((network) => hasRuntimeConfig(network));
let activeNetwork: OracleNetwork =
  preferredOrder.find((network) => supportedNetworks.includes(network) && hasRuntimeConfig(network)) ??
  firstConfiguredNetwork ??
  (supportedNetworks.includes(configuredDefault) ? configuredDefault : supportedNetworks[0]!);

function pickNetworkValue(network: OracleNetwork, key: string, fallback = ""): string {
  const scopedKey = `${networkPrefix(network)}_${key}`;
  if (hasScopedNetworkConfig(key)) {
    return process.env[scopedKey]?.trim() || fallback;
  }
  return process.env[key]?.trim() || fallback;
}

export function getActiveNetwork(): OracleNetwork {
  return activeNetwork;
}

export function setActiveNetwork(next: string): OracleNetwork {
  const normalized = normalizeNetwork(next);
  if (!supportedNetworks.includes(normalized)) {
    throw new Error(`Unsupported network: ${next}`);
  }
  activeNetwork = normalized;
  return activeNetwork;
}

export function getSupportedNetworks(): OracleNetwork[] {
  return [...supportedNetworks];
}

export function getRuntimeConfig(network = activeNetwork) {
  const selected = normalizeNetwork(network);
  return {
    network: selected,
    rpcUrl: pickNetworkValue(selected, "IOTA_RPC_URL", "https://api.mainnet.iota.cafe"),
    graphqlUrl: pickNetworkValue(selected, "IOTA_GRAPHQL_URL"),
    oracleTasksPackageId: pickNetworkValue(selected, "ORACLE_TASKS_PACKAGE_ID"),
    oracleSystemPackageId: pickNetworkValue(selected, "ORACLE_SYSTEM_PACKAGE_ID"),
    oracleStateId: pickNetworkValue(selected, "ORACLE_STATE_ID", pickNetworkValue(selected, "ORACLE_SYSTEM_STATE_ID", pickNetworkValue(selected, "ORACLE_STATUS_ID"))),
    oracleNodeRegistryId: pickNetworkValue(selected, "ORACLE_NODE_REGISTRY_ID"),
    oracleTreasuryId: pickNetworkValue(selected, "ORACLE_TREASURY_ID", pickNetworkValue(selected, "ORACLE_TREASURY_OBJECT_ID")),
    oracleTaskRegistryId: pickNetworkValue(selected, "ORACLE_TASK_REGISTRY_ID"),
    oracleTaskSchedulerQueueId: pickNetworkValue(selected, "ORACLE_TASK_SCHEDULER_QUEUE_ID"),
    iotaRandomObjectId: pickNetworkValue(selected, "IOTA_RANDOM_OBJECT_ID"),
    iotaClockObjectId: pickNetworkValue(selected, "IOTA_CLOCK_OBJECT_ID", pickNetworkValue(selected, "IOTA_CLOCK_ID")),
  };
}

export const config = {
  port: toNumber(process.env.PORT, 8787),
  oracleTaskModule: process.env.ORACLE_TASK_MODULE ?? "oracle_tasks",
  oracleMessageModule: process.env.ORACLE_MESSAGE_MODULE ?? "oracle_messages",
  activeWindowMinutes: toNumber(process.env.ACTIVE_WINDOW_MINUTES, 2),
  eventFetchLimit: toNumber(process.env.EVENT_FETCH_LIMIT, 100),
  eulaSourceUrl: envAny("EULA_SOURCE_URL", "GIT_EULA_URL", "EULA_RAW_URL") || defaultEulaSourceUrl,
  eulaSourceToken: process.env.EULA_SOURCE_TOKEN?.trim() || "",
  oracleNodeAddresses: toList(process.env.ORACLE_NODE_ADDRESSES),
  oracleClientDir: clientDir,
  oracleExamplesDir: examplesDir,
};

export const envDebug = {
  cwd: rootDir,
  envFileLoaded: Boolean(
    process.env.ORACLE_TASKS_PACKAGE_ID ||
      process.env.ORACLE_SYSTEM_PACKAGE_ID ||
      process.env.ORACLE_PACKAGE_ID ||
      process.env.IOTA_RPC_URL ||
      process.env.IOTA_GRAPHQL_URL ||
      process.env.PORT,
  ),
};
