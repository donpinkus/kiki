/**
 * Boot-validation harness: launch ONE serving instance exactly the way the
 * pool does (cloud-init → boot.sh off the region filesystem), poll /health
 * until ready, print the full boot decomposition (provision / OS / stack +
 * phase timings from the server's own /health clocks), then terminate.
 *
 * Used to verify model-server boot changes (e.g. the 2026-08-22 video weight
 * prefetch) on a real cold boot without touching the production pools —
 * kiki-boottest-* names are never adopted.
 *
 * Usage (from backend/):
 *   npx tsx scripts/lambda/validate-boot.mts --server video [--region us-south-2] [--type gpu_1x_h100_sxm5]
 *   npx tsx scripts/lambda/validate-boot.mts --server image
 */
import { request as httpsRequest } from 'node:https';
import { requireClient, launchWithRetry, sleep } from './lambdaApi.js';

function getArg(flag: string, dflt: string): string {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 && process.argv[idx + 1] ? process.argv[idx + 1]! : dflt;
}

const SERVER = getArg('--server', 'video'); // 'image' | 'video'
const REGION = getArg('--region', 'us-south-2');
const TYPE = getArg('--type', 'gpu_1x_h100_sxm5');
const FS_NAME = SERVER === 'video' ? `kiki-video-${REGION}` : `kiki-image-${REGION}`;
const PORT = 8766;
const BOOT_TIMEOUT_MS = 30 * 60_000;

const client = requireClient();

function health(ip: string): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      { host: ip, port: PORT, path: '/health', rejectUnauthorized: false, timeout: 4000 },
      (res) => {
        let body = '';
        res.on('data', (c: Buffer) => (body += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body) as Record<string, unknown>);
          } catch (e) {
            reject(e as Error);
          }
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end();
  });
}

const name = `kiki-boottest-${SERVER}-${Date.now()}`;
const userData = `#cloud-config
runcmd:
  - [systemd-run, --unit=kiki, --property=Restart=on-failure, bash, /lambda/nfs/${FS_NAME}/kiki/boot.sh]
`;

const keys = await client.listSshKeys();
console.log(`[validate] launching ${TYPE}@${REGION} fs=${FS_NAME} as ${name}`);
const t0 = Date.now();
const [id] = await launchWithRetry(
  client,
  {
    region_name: REGION,
    instance_type_name: TYPE,
    ssh_key_names: [keys[0]!.name],
    file_system_names: [FS_NAME],
    name,
    image: { family: 'lambda-stack-24-04' },
    user_data: userData,
  },
  15,
);
const launchMs = Date.now();
console.log(`[validate] accepted id=${id} (search ${(launchMs - t0) / 1000}s)`);

try {
  let ip: string | undefined;
  let ipAtMs = 0;
  for (;;) {
    if (Date.now() - launchMs > BOOT_TIMEOUT_MS) throw new Error('boot timed out');
    if (!ip) {
      const inst = await client.getInstance(id!);
      if (inst.ip) {
        ip = inst.ip;
        ipAtMs = Date.now();
        console.log(`[validate] ip=${ip} after ${Math.round((ipAtMs - launchMs) / 1000)}s`);
      }
    }
    if (ip) {
      try {
        const h = await health(ip);
        if (h['status'] === 'ok') {
          const readyMs = Date.now();
          const booted = h['booted_at_epoch_s'] as number | undefined;
          const started = h['started_at_epoch_s'] as number | undefined;
          console.log(`\n[validate] READY in ${Math.round((readyMs - launchMs) / 1000)}s total`);
          if (booted) console.log(`  provision_s (launch→kernel): ${Math.round(booted - launchMs / 1000)}`);
          if (booted && started) console.log(`  os_s (kernel→process):      ${started - booted}`);
          if (started) console.log(`  stack_s (process→ready):    ${Math.round(readyMs / 1000 - started)}`);
          console.log(`  phase_timings_ms: ${JSON.stringify(h['phase_timings_ms'])}`);
          break;
        }
      } catch {
        // not up yet
      }
    }
    await sleep(5000);
  }
} finally {
  console.log(`[validate] terminating ${id}`);
  await client.terminate([id!]).catch((e: Error) => console.log(`terminate failed: ${e.message}`));
}
