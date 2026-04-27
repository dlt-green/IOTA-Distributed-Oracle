import { getNetwork, Network, type ChainType } from "@iota/iota-sdk/client";
import type { OracleNetwork } from "../types";

const SDK_NETWORK_BY_ORACLE_NETWORK: Record<OracleNetwork, Network> = {
  mainnet: Network.Mainnet,
  testnet: Network.Testnet,
  devnet: Network.Devnet,
};

const FALLBACK_CHAIN_BY_ORACLE_NETWORK: Record<OracleNetwork, ChainType> = {
  mainnet: "iota:mainnet",
  testnet: "iota:testnet",
  devnet: "iota:devnet",
};

export function getChainForOracleNetwork(network: OracleNetwork): ChainType {
  try {
    return getNetwork(SDK_NETWORK_BY_ORACLE_NETWORK[network]).chain;
  } catch {
    return FALLBACK_CHAIN_BY_ORACLE_NETWORK[network];
  }
}
