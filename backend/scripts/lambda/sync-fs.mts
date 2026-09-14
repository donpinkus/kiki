/**
 * Sync local model-servers/ onto a region filesystem's kiki/app WITHOUT a
 * full setup-lambda run: launches the cheapest instance type with capacity
 * in the region, attaches the filesystem, rsyncs, terminates. ~5-10 min,
 * usually < $0.50.
 *
 * A running instance that already mounts the filesystem is cheaper still —
 * rsync through it directly; this script is for when none is up.
 *
 * Usage (from backend/):
 *   npx tsx scripts/lambda/sync-fs.mts --region us-south-2 [--fs kiki-image-us-south-2]
 */
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { requireClient, launchWithRetry, sleep, REPO_ROOT } from './lambdaApi.js';

function getArg(flag: string, dflt?: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 && process.argv[idx + 1] ? process.argv[idx + 1] : dflt;
}

const REGION = getArg('--region');
if (!REGION) {
  console.error('Usage: npx tsx scripts/lambda/sync-fs.mts --region <region> [--fs <name>]');
  process.exit(1);
}
const FS_NAME = getArg('--fs', `kiki-image-${REGION}`)!;

const client = requireClient();
const types = Object.values(await client.listInstanceTypes());
const inRegion = types
  .filter((t) => t.regions_with_capacity_available.some((r) => r.name === REGION))
  .sort((a, b) => a.instance_type.price_cents_per_hour - b.instance_type.price_cents_per_hour);
const pick = inRegion[0];
if (!pick) throw new Error(`no capacity of any instance type in ${REGION} right now`);
console.log(
  `[sync-fs] ${REGION}/${FS_NAME} via ${pick.instance_type.name} ($${(pick.instance_type.price_cents_per_hour / 100).toFixed(2)}/hr)`,
);

const keys = await client.listSshKeys();
const [id] = await launchWithRetry(
  client,
  {
    region_name: REGION,
    instance_type_name: pick.instance_type.name,
    ssh_key_names: [keys[0]!.name],
    file_system_names: [FS_NAME],
    name: `kiki-fssync-${Date.now()}`,
    image: { family: 'lambda-stack-24-04' },
  },
  5,
);
console.log(`[sync-fs] launched ${id}`);
try {
  let ip: string | undefined;
  for (let i = 0; i < 240 && !ip; i++) {
    const inst = await client.getInstance(id!);
    ip = inst.ip ?? undefined;
    if (!ip) await sleep(5000);
  }
  if (!ip) throw new Error('no ip');
  console.log(`[sync-fs] ip ${ip}; waiting for SSH + mount...`);
  const sshBase = [
    '-i', resolve(homedir(), '.ssh/id_ed25519'),
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'ConnectTimeout=8',
    '-o', 'BatchMode=yes',
  ];
  let up = false;
  for (let i = 0; i < 180; i++) {
    try {
      execFileSync('ssh', [...sshBase, `ubuntu@${ip}`, `test -d /lambda/nfs/${FS_NAME} && echo up`], { timeout: 15_000 });
      up = true;
      break;
    } catch {
      await sleep(5000);
    }
  }
  if (!up) throw new Error('ssh/filesystem never came up');
  execFileSync(
    'rsync',
    [
      '-az', '--delete',
      '--exclude', '__pycache__', '--exclude', '*.pyc', '--exclude', 'dev/',
      '-e', `ssh ${sshBase.join(' ')}`,
      resolve(REPO_ROOT, 'model-servers') + '/',
      `ubuntu@${ip}:/lambda/nfs/${FS_NAME}/kiki/app/`,
    ],
    { stdio: 'inherit', timeout: 300_000 },
  );
  console.log(`[sync-fs] ${FS_NAME} synced`);
} finally {
  await client.terminate([id!]);
  console.log(`[sync-fs] terminated ${id}`);
}
