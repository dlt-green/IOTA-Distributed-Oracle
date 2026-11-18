import type { IotaClient } from '@iota/iota-sdk/client';
import type { Transaction } from '@iota/iota-sdk/transactions';

// SDK 1.17 removed serialize(). Keep preparation as unsigned JSON so the wallet
// can resolve and sign the transaction without server-side keys or gas selection.
export function serializeTransactionForWallet(tx: Transaction, client: IotaClient): Promise<string> {
  return tx.toJSON({ client });
}
