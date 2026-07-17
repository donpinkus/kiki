/**
 * List / terminate Lambda Cloud instances. Safety valve so nothing keeps billing.
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/instances.ts                       # list
 *   tsx scripts/lambda/instances.ts --terminate <id>
 *   tsx scripts/lambda/instances.ts --terminate-all       # kiki-* named instances only
 */

import { requireClient } from './lambdaApi.js';

const client = requireClient();
const instances = await client.listInstances();

if (instances.length === 0) {
  console.log('No instances.');
  process.exit(0);
}

for (const i of instances) {
  console.log(
    `${i.id}  ${(i.name ?? '').padEnd(28)} ${i.instance_type.name.padEnd(22)} ${i.region.name.padEnd(12)} ` +
      `${i.status.padEnd(10)} ip=${i.ip ?? '-'}  $${(i.instance_type.price_cents_per_hour / 100).toFixed(2)}/hr`,
  );
}

const termIdx = process.argv.indexOf('--terminate');
if (termIdx !== -1) {
  const id = process.argv[termIdx + 1];
  if (!id) {
    console.error('--terminate requires an instance id');
    process.exit(1);
  }
  await client.terminate([id]);
  console.log(`Terminated ${id}.`);
} else if (process.argv.includes('--terminate-all')) {
  const kiki = instances.filter((i) => i.name?.startsWith('kiki-') && i.status !== 'terminated');
  if (kiki.length === 0) {
    console.log('No kiki-* instances to terminate.');
  } else {
    await client.terminate(kiki.map((i) => i.id));
    console.log(`Terminated: ${kiki.map((i) => `${i.id} (${i.name})`).join(', ')}`);
  }
}
