// Read-only deployment checks. No private keys, signing or transaction submission.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { IotaClient } from '@iota/iota-sdk/client';
import { Transaction } from '@iota/iota-sdk/transactions';

const manifest = JSON.parse(fs.readFileSync(fileURLToPath(new URL('../../move/testnet/deployment.json', import.meta.url)), 'utf8'));
const snapshot = JSON.parse(fs.readFileSync(fileURLToPath(new URL('../../move/testnet/approved_templates_snapshot.json', import.meta.url)), 'utf8'));
const ids = manifest.ids;
const client = new IotaClient({ url: 'https://api.testnet.iota.cafe' });
const system = ids.TESTNET_ORACLE_SYSTEM_PACKAGE_ID;
const tasks = ids.TESTNET_ORACLE_TASKS_PACKAGE_ID;
const registryId = ids.TESTNET_ORACLE_NODE_REGISTRY_ID;
const sender = manifest.publisher;
for (const digest of Object.values(manifest.transactions) as string[]) {
  const tx = await client.getTransactionBlock({ digest, options: { showEffects: true } });
  assert.equal(tx.effects?.status.status, 'success');
}
for (const [key, type] of Object.entries({
  TESTNET_ORACLE_STATE_ID: `${system}::systemState::State`,
  TESTNET_ORACLE_NODE_REGISTRY_ID: `${system}::systemState::NodeRegistry`,
  TESTNET_ORACLE_TASK_REGISTRY_ID: `${tasks}::oracle_tasks::TaskRegistry`,
  TESTNET_ORACLE_TASK_SCHEDULER_QUEUE_ID: `${tasks}::oracle_tasks::SchedulerQueue`,
})) {
  const obj = await client.getObject({ id: ids[key], options: { showType: true, showContent: true } });
  assert.equal(obj.data?.type, type);
  if (key === 'TESTNET_ORACLE_STATE_ID') {
    const fields = (obj.data?.content as any).fields;
    assert.equal(fields.node_registry_id, registryId);
    assert.equal(fields.system_fee_bps, '500');
  }
}
const module = await client.getNormalizedMoveModule({ package: tasks, module: 'oracle_tasks' });
assert.ok(module.exposedFunctions.finalize_task_with_certificate);
assert.equal(module.exposedFunctions.append_result_for_testing, undefined);
assert.ok(JSON.stringify(module.exposedFunctions.create_task).includes(system));

async function inspectDev(packageId: string) {
  const tx = new Transaction();
  tx.moveCall({ target: `${packageId}::systemState::register_oracle_node_dev`, arguments: [
    tx.object(registryId), tx.pure.address(sender), tx.pure.vector('u8', Array(32).fill(0)), tx.pure.vector('u64', [9]),
  ] });
  const result = await client.devInspectTransactionBlock({ sender, transactionBlock: tx });
  assert.equal(result.effects.status.status, 'failure');
  return result.effects.status.error ?? result.error ?? '';
}
const denied = await inspectDev(system);
assert.match(denied, /Move(?: Runtime )?Abort/);
assert.match(denied, /\b7\b/);
const legacyDenied = await inspectDev(manifest.previous_system_package);
assert.match(legacyDenied, /Type.?Mismatch|type mismatch|type of the value does not match the expected type/i);

const page = await client.getDynamicFields({ parentId: ids.TESTNET_ORACLE_STATE_ID, limit: 50 });
assert.equal(page.hasNextPage, false);
const templateObjects = page.data.filter(x => x.name.type === `${system}::systemState::TaskTemplateKey`);
assert.equal(templateObjects.length, snapshot.templates.length);
for (const item of templateObjects) {
  const object = await client.getObject({ id: item.objectId, options: { showContent: true } });
  const fields = (object.data?.content as any).fields.value.fields;
  const expected = snapshot.templates.find((t: any) => t.fields.template_id === fields.template_id);
  assert.deepEqual(fields, expected.fields);
}
console.log(JSON.stringify({ network: 'testnet', publication: 'success', devRegistration: denied,
  legacyPackageNewRegistry: legacyDenied, productionTestHelper: 'absent', approvedTemplates: templateObjects.length,
  positiveValidatorRegistration: 'not tested; partner with a valid delegated cap required' }, null, 2));
