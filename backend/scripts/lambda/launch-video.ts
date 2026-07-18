/**
 * Launch (or manage) the dedicated Lambda VIDEO serving instance (LTX-2.3).
 *
 * POC topology: ONE static `kiki-video-*` instance, launched manually with
 * this script; the backend reaches it via the printed LAMBDA_VIDEO_URL env
 * (no pool/autoscaler yet — see documents/plans/lambda-video-provider.md for
 * the path to a devPool-style manager). The WS token is a deterministic
 * HMAC(LAMBDA_API_KEY, instance-name) — the same scheme as the image pool —
 * so the URL stays valid across backend redeploys.
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/launch-video.ts --region us-south-2 [--type gpu_1x_h100_sxm5] [--retry-mins 30]
 *   tsx scripts/lambda/launch-video.ts --list          # show kiki-video-* instances (+ their URLs)
 *   tsx scripts/lambda/launch-video.ts --terminate     # terminate all kiki-video-* instances
 *
 * Prereq: scripts/lambda/setup-lambda-video.ts has populated
 * `kiki-video-<region>` in the target region. Requires LAMBDA_API_KEY in
 * .env.local.
 *
 * The instance boots via cloud-init → systemd-run → boot.sh on the
 * filesystem; readiness = OUR /health returning status ok (never Lambda's
 * `active`, which lags 27-62s). First-ever boot per region pays the full
 * model load (~5-10 min); NFS page cache makes later boots faster.
 */

import { createHmac } from 'node:crypto';
import { request as httpsRequest } from 'node:https';
import { request as httpRequest } from 'node:http';
import { launchWithRetry, requireClient, sleep } from './lambdaApi.js';

const KIKI_PORT = 8766;
const NAME_PREFIX = 'kiki-video-';
const OS_IMAGE_FAMILY = 'lambda-stack-24-04';
const BOOT_TIMEOUT_MS = 30 * 60 * 1000;

function getArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 ? process.argv[idx + 1] : undefined;
}

const client = requireClient();
const apiKey = process.env['LAMBDA_API_KEY']!;

/** Deterministic per-instance WS token — same scheme as devPool.wsToken. */
function wsToken(name: string): string {
  return createHmac('sha256', apiKey).update(name).digest('hex').slice(0, 32);
}

/** GET /health accepting the fleet's self-signed cert (or plain http when
 * the filesystem has no TLS cert). Returns the parsed body + which scheme
 * answered, so the printed URL uses the right ws/wss. */
function probeHealth(ip: string, timeoutMs: number): Promise<{ body: { status?: string }; scheme: 'wss' | 'ws' }> {
  const tryHttps = (): Promise<{ body: { status?: string }; scheme: 'wss' }> =>
    new Promise((resolve, reject) => {
      const req = httpsRequest(
        { host: ip, port: KIKI_PORT, path: '/health', rejectUnauthorized: false, timeout: timeoutMs },
        (res) => {
          let body = '';
          res.on('data', (c: Buffer) => (body += c));
          res.on('end', () => {
            try {
              resolve({ body: JSON.parse(body) as { status?: string }, scheme: 'wss' });
            } catch (err) {
              reject(err as Error);
            }
          });
        },
      );
      req.on('timeout', () => req.destroy(new Error('health timeout')));
      req.on('error', reject);
      req.end();
    });
  const tryHttp = (): Promise<{ body: { status?: string }; scheme: 'ws' }> =>
    new Promise((resolve, reject) => {
      const req = httpRequest(
        { host: ip, port: KIKI_PORT, path: '/health', timeout: timeoutMs },
        (res) => {
          let body = '';
          res.on('data', (c: Buffer) => (body += c));
          res.on('end', () => {
            try {
              resolve({ body: JSON.parse(body) as { status?: string }, scheme: 'ws' });
            } catch (err) {
              reject(err as Error);
            }
          });
        },
      );
      req.on('timeout', () => req.destroy(new Error('health timeout')));
      req.on('error', reject);
      req.end();
    });
  return tryHttps().catch(() => tryHttp());
}

function videoUrl(name: string, ip: string, scheme: 'wss' | 'ws'): string {
  return `${scheme}://${ip}:${KIKI_PORT}/ws?token=${wsToken(name)}`;
}

// ── --list / --terminate ────────────────────────────────────────────────────
if (process.argv.includes('--list') || process.argv.includes('--terminate')) {
  const all = (await client.listInstances()).filter((i) => i.name?.startsWith(NAME_PREFIX));
  if (all.length === 0) {
    console.log('[video] no kiki-video-* instances');
    process.exit(0);
  }
  for (const i of all) {
    console.log(`[video] ${i.name} id=${i.id} status=${i.status} ip=${i.ip ?? '-'} region=${i.region.name}`);
    if (i.ip && i.status === 'active') {
      try {
        const { body, scheme } = await probeHealth(i.ip, 4000);
        console.log(`        health=${body.status ?? '?'}  LAMBDA_VIDEO_URL=${videoUrl(i.name!, i.ip, scheme)}`);
      } catch (err) {
        console.log(`        health unreachable (${(err as Error).message})`);
      }
    }
  }
  if (process.argv.includes('--terminate')) {
    console.log(`[video] terminating ${all.length} instance(s)...`);
    await client.terminate(all.map((i) => i.id));
    console.log('[video] terminated.');
  }
  process.exit(0);
}

// ── launch ──────────────────────────────────────────────────────────────────
const REGION = getArg('--region');
const TYPE = getArg('--type') ?? 'gpu_1x_h100_sxm5';
const RETRY_MINS = Number(getArg('--retry-mins') ?? '0');
if (!REGION) {
  console.error(
    'Usage: tsx scripts/lambda/launch-video.ts --region <region> [--type gpu_1x_h100_sxm5] [--retry-mins 30]\n' +
      '       tsx scripts/lambda/launch-video.ts --list | --terminate',
  );
  process.exit(1);
}
const FS_NAME = getArg('--fs') ?? `kiki-video-${REGION}`;

// Reuse any live instance first — a warm instance is also a capacity
// reservation; don't burn it by double-launching.
const existing = (await client.listInstances()).filter(
  (i) => i.name?.startsWith(NAME_PREFIX) && !i.name.startsWith('kiki-video-setup-') && ['booting', 'active'].includes(i.status),
);
let name: string;
let instanceId: string;
if (existing.length > 0) {
  const inst = existing[0]!;
  name = inst.name!;
  instanceId = inst.id;
  console.log(`[video] reusing existing instance ${name} (${inst.status})`);
} else {
  name = `${NAME_PREFIX}${Date.now()}`;
  const keys = await client.listSshKeys();
  if (keys.length === 0) {
    console.error('[video] no SSH key registered — run setup-lambda-video.ts first');
    process.exit(1);
  }
  const userData = `#cloud-config
write_files:
  - path: /etc/kiki.env
    permissions: '0600'
    content: |
      KIKI_WS_TOKEN=${wsToken(name)}
runcmd:
  - [systemd-run, --unit=kiki, --property=Restart=on-failure, bash, /lambda/nfs/${FS_NAME}/kiki/boot.sh]
`;
  console.log(`[video] launching ${name} in ${REGION} (${TYPE})...`);
  const [id] = await launchWithRetry(
    client,
    {
      region_name: REGION,
      instance_type_name: TYPE,
      ssh_key_names: [keys[0]!.name],
      file_system_names: [FS_NAME],
      name,
      image: { family: OS_IMAGE_FAMILY },
      user_data: userData,
    },
    RETRY_MINS,
  );
  if (!id) {
    console.error('[video] launch returned no instance id');
    process.exit(1);
  }
  instanceId = id;
  console.log(`[video] launched ${instanceId}`);
}

// IP first (shows up during `booting`, ~25s in), then OUR /health.
const t0 = Date.now();
let ip: string | undefined;
while (!ip) {
  if (Date.now() - t0 > BOOT_TIMEOUT_MS) {
    console.error('[video] timed out waiting for IP');
    process.exit(1);
  }
  try {
    const inst = await client.getInstance(instanceId);
    if (['terminated', 'terminating', 'unhealthy', 'preempted'].includes(inst.status)) {
      console.error(`[video] instance entered ${inst.status} during boot`);
      process.exit(1);
    }
    ip = inst.ip ?? undefined;
  } catch {
    // transient API error — keep polling
  }
  if (!ip) await sleep(5000);
}
console.log(`[video] ip=${ip} at t+${((Date.now() - t0) / 1000).toFixed(0)}s; polling /health (model load ~5-10 min on cold NFS cache)...`);

for (;;) {
  if (Date.now() - t0 > BOOT_TIMEOUT_MS) {
    console.error('[video] timed out waiting for /health ok — ssh in and check `journalctl -u kiki`');
    process.exit(1);
  }
  try {
    const { body, scheme } = await probeHealth(ip, 4000);
    if (body.status === 'ok') {
      const url = videoUrl(name, ip, scheme);
      console.log(`\n[video] READY after ${((Date.now() - t0) / 1000).toFixed(0)}s (scheme=${scheme})`);
      console.log(`\n  LAMBDA_VIDEO_URL=${url}\n`);
      console.log('  Backend enablement:');
      console.log('   - local dev:  add the line above to backend .env / shell env');
      console.log('   - production: set it on Railway, then `cd backend && npm run deploy`');
      console.log('  Test without the iPad:');
      console.log(`   - python3 model-servers/dev/video_client.py --url '${url}' --image backend/scripts/lambda/test-sketch.jpg --prompt "gentle motion" ${scheme === 'wss' ? '--insecure' : ''}`);
      console.log('\n  BILLING: instance runs until `tsx scripts/lambda/launch-video.ts --terminate`');
      process.exit(0);
    }
    if (body.status === 'error') {
      console.error('[video] /health reports load error — ssh in and check; body:', JSON.stringify(body).slice(0, 800));
      process.exit(1);
    }
    console.log(`[video] t+${((Date.now() - t0) / 1000).toFixed(0)}s health=${body.status ?? '?'}...`);
  } catch {
    // not up yet
  }
  await sleep(10_000);
}
