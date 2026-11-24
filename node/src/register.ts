// Copyright (c) 2026 Stefano Della Valle
// SPDX-License-Identifier: LicenseRef-Proprietary

import { Transaction } from "@iota/iota-sdk/transactions";
import type { IotaClient } from "@iota/iota-sdk/client";
import type { Ed25519Keypair } from "@iota/iota-sdk/keypairs/ed25519";

import { bcsAddress, bcsVecU8, bcsVecU64 } from "./bcs";
import { signAndExecuteWithLockRetry } from "./txRetry.js";
import { resolveRegisterMode, validateRegistrationState } from "./registrationPolicy.js";

export async function registerOracleNodeDev(args: {
  client: IotaClient;
  signer: Ed25519Keypair;
  packageId: string;
  systemStateId: string;
  oracleAddr: string;
  pubkeyBytes: Uint8Array;
  acceptedTemplateIds: number[];
}): Promise<string> {
  const { client, signer, packageId, systemStateId, oracleAddr, pubkeyBytes, acceptedTemplateIds } = args;
  if (resolveRegisterMode(process.env.IOTA_NETWORK, "dev") !== "dev") {
    throw new Error("Dev registration requires an explicit devnet/localnet network.");
  }
  const registryId = await validateRegistrationState(client, systemStateId, packageId);

  const res = await signAndExecuteWithLockRetry({
    client,
    signer,
    transactionFactory: () => {
      const tx = new Transaction();
      tx.moveCall({
        target: `${packageId}::systemState::register_oracle_node_dev`,
        arguments: [
          tx.object(registryId),
          tx.pure(bcsAddress(oracleAddr)),
          tx.pure(bcsVecU8(pubkeyBytes)),
          tx.pure(bcsVecU64(acceptedTemplateIds)),
        ],
      });
      return tx;
    },
    options: {
      showEffects: true,
      showObjectChanges: true,
      showEvents: true,
    },
    label: "registerOracleNodeDev",
  });

  await client.waitForTransaction({ digest: res.digest });
  return res.digest;
}
