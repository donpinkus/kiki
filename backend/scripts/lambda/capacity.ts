/**
 * Probe Lambda Cloud instance types, live capacity, and prices.
 * Also validates the API key. Run this first.
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/capacity.ts             # all types with capacity
 *   tsx scripts/lambda/capacity.ts --all       # include types with no capacity
 *   tsx scripts/lambda/capacity.ts --filter h100
 */

import { requireClient } from './lambdaApi.js';

const showAll = process.argv.includes('--all');
const filterIdx = process.argv.indexOf('--filter');
const filter = filterIdx !== -1 ? process.argv[filterIdx + 1]?.toLowerCase() : undefined;

const client = requireClient();
const types = await client.listInstanceTypes();

const rows = Object.values(types)
  .filter((t) => !filter || t.instance_type.name.toLowerCase().includes(filter))
  .filter((t) => showAll || t.regions_with_capacity_available.length > 0)
  .sort((a, b) => a.instance_type.price_cents_per_hour - b.instance_type.price_cents_per_hour);

if (rows.length === 0) {
  console.log(filter ? `No instance types matching '${filter}' with capacity.` : 'No capacity anywhere.');
  process.exit(0);
}

for (const t of rows) {
  const it = t.instance_type;
  const regions = t.regions_with_capacity_available.map((r) => r.name).join(', ') || '(none)';
  console.log(
    `${it.name.padEnd(28)} $${(it.price_cents_per_hour / 100).toFixed(2)}/hr  ` +
      `${String(it.specs.gpus).padStart(2)}x GPU  ${String(it.specs.vcpus).padStart(3)} vCPU  ` +
      `${String(it.specs.memory_gib).padStart(4)} GiB  → ${regions}`,
  );
}

// Also show any instances currently running (so nothing is forgotten + billing).
const instances = await client.listInstances();
if (instances.length > 0) {
  console.log('\nRunning instances (billing!):');
  for (const i of instances) {
    console.log(
      `  ${i.id}  ${i.name ?? ''}  ${i.instance_type.name}  ${i.region.name}  ${i.status}  ip=${i.ip ?? '-'}`,
    );
  }
} else {
  console.log('\nNo running instances.');
}
