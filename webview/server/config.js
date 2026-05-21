// Copyright (c) 2026 Stefano Della Valle
// SPDX-License-Identifier: LicenseRef-Proprietary
import "dotenv/config";
import path from "node:path";
const ALL_NETWORKS = ["mainnet", "testnet", "devnet"];
function toNumber(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : fallback;
}
function toList(value) {
    return String(value ?? "")
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean);
}
function envAny(...names) {
    for (const name of names) {
        const value = process.env[name]?.trim();
        if (value)
            return value;
    }
    return "";
}
function normalizeNetwork(value) {
    const raw = String(value ?? "").trim().toLowerCase();
    if (raw === "dev" || raw === "devnet")
        return "devnet";
    if (raw === "test" || raw === "testnet")
        return "testnet";
    return "mainnet";
}
function networkPrefix(network) {
    return network.toUpperCase();
}
function hasScopedNetworkConfig(key) {
    return ALL_NETWORKS.some((network) => Object.prototype.hasOwnProperty.call(process.env, `${networkPrefix(network)}_${key}`));
}
const rootDir = process.cwd();
const clientDir = path.resolve(rootDir, process.env.ORACLE_CLIENT_DIR ?? "../iota_oracle_client");
const examplesDirRaw = process.env.ORACLE_EXAMPLES_DIR?.trim() || process.env.ORACLE_CLIENT_EXAMPLES_DIR?.trim() || "examples";
const examplesDir = path.resolve(rootDir, examplesDirRaw);
const supportedNetworks = toList(process.env.VITE_SUPPORTED_NETWORKS)
    .map((n) => normalizeNetwork(n))
    .filter((n, i, arr) => arr.indexOf(n) === i);
if (supportedNetworks.length === 0)
    supportedNetworks.push("mainnet", "testnet", "devnet");
const configuredDefault = normalizeNetwork(process.env.WEBVIEW_DEFAULT_NETWORK ?? process.env.VITE_DEFAULT_NETWORK ?? "mainnet");
let activeNetwork = supportedNetworks.includes(configuredDefault) ? configuredDefault : "mainnet";
if (!supportedNetworks.includes(activeNetwork))
    activeNetwork = supportedNetworks[0];
function pickNetworkValue(network, key, fallback = "") {
    const scopedKey = `${networkPrefix(network)}_${key}`;
    if (hasScopedNetworkConfig(key)) {
        return process.env[scopedKey]?.trim() || fallback;
    }
    return process.env[key]?.trim() || fallback;
}
export function getActiveNetwork() {
    return activeNetwork;
}
export function setActiveNetwork(next) {
    const normalized = normalizeNetwork(next);
    if (!supportedNetworks.includes(normalized)) {
        throw new Error(`Unsupported network: ${next}`);
    }
    activeNetwork = normalized;
    return activeNetwork;
}
export function getSupportedNetworks() {
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
    oracleNodeAddresses: toList(process.env.ORACLE_NODE_ADDRESSES),
    oracleClientDir: clientDir,
    oracleExamplesDir: examplesDir,
};
export const envDebug = {
    cwd: rootDir,
    envFileLoaded: Boolean(process.env.ORACLE_TASKS_PACKAGE_ID ||
        process.env.ORACLE_SYSTEM_PACKAGE_ID ||
        process.env.ORACLE_PACKAGE_ID ||
        process.env.IOTA_RPC_URL ||
        process.env.IOTA_GRAPHQL_URL ||
        process.env.PORT),
};
