import type { IotaClient } from "@iota/iota-sdk/client";
import { normalizeIotaAddress } from "@iota/iota-sdk/utils";
import { normalizeNetwork } from "./config/env.js";
import { getMoveFields, moveToString } from "./utils/move.js";

export function resolveRegisterMode(networkRaw = process.env.IOTA_NETWORK, modeRaw = process.env.REGISTER_MODE): "off" | "dev" | "prod" {
  const network = normalizeNetwork(networkRaw);
  if (!network) throw new Error("Set an explicit valid IOTA_NETWORK before registration.");
  const mode = String(modeRaw ?? "").trim().toLowerCase();
  if (["off", "false", "0"].includes(mode)) return "off";
  if (mode && mode !== "dev" && mode !== "prod") throw new Error(`Invalid REGISTER_MODE: ${mode}`);
  const dev = network === "devnet" || network === "localnet";
  if (mode === "dev" && !dev) throw new Error("REGISTER_MODE=dev is forbidden on testnet/mainnet; use prod and a delegated cap.");
  return mode === "prod" ? "prod" : dev ? "dev" : "prod";
}

// Fresh publications must use one coherent set of package and object IDs.
// Never silently replace the configured package with the package of an old State.
export async function validateRegistrationState(
  client: IotaClient, stateId: string, packageId: string, configuredRegistryId?: string,
): Promise<string> {
  const response = await client.getObject({ id: stateId, options: { showContent: true, showType: true } });
  const content: any = response.data?.content;
  const type = String(response.data?.type ?? content?.type ?? "");
  const [origin, module, name] = type.split("::");
  if (!origin || module !== "systemState" || name !== "State" || normalizeIotaAddress(origin) !== normalizeIotaAddress(packageId)) {
    throw new Error("Registration package/State mismatch. Update all IDs from the same deployment; refusing legacy fallback.");
  }
  const fields = getMoveFields(response);
  const rawNetwork = fields.network;
  const stateNetwork = normalizeNetwork(Array.isArray(rawNetwork) ? String.fromCharCode(...rawNetwork) : moveToString(rawNetwork));
  const configuredNetwork = normalizeNetwork(process.env.IOTA_NETWORK);
  if (!stateNetwork || !configuredNetwork || stateNetwork !== (configuredNetwork === "localnet" ? "devnet" : configuredNetwork)) {
    throw new Error("Registration State network does not match IOTA_NETWORK.");
  }
  const registryId = moveToString(fields.node_registry_id).trim();
  if (!registryId || (configuredRegistryId && normalizeIotaAddress(configuredRegistryId) !== normalizeIotaAddress(registryId))) {
    throw new Error("Registration State/NodeRegistry mismatch. Update the registry ID from the same deployment.");
  }
  return registryId;
}
