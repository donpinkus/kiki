/**
 * Measure Lambda VM PROVISIONING time — the launch-API-accept → kernel-boot
 * window that dominates slow pool boots (diagnosed 2026-08-22: an image-pool
 * instance spent 14 min provisioning + 3 min in our stack, while a video
 * instance launched 5 min earlier in the same region provisioned in 2.5 min).
 *
 * Launches N probe instances (name kiki-boottest-* — never adopted by the
 * pools), records per-instance:
 *   - launch accepted → API status 'active'
 *   - launch accepted → IP visible in the API
 *   - launch accepted → SSH reachable
 *   - kernel boot time (uptime -s over SSH) → true provisioning duration
 * then terminates them. No filesystem writes; instances attach the image FS
 * read-only-in-practice to match the prod launch shape.
 *
 * Usage (from backend/):
 *   npx tsx scripts/lambda/boot-probe.mts [--n 3] [--region us-south-2] [--type gpu_1x_h100_sxm5]
 */
import { execFile } from 'node:child_process';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { promisify } from 'node:util';
import { requireClient, launchWithRetry, sleep } from './lambdaApi.js';

const execFileP = promisify(execFile);

function getArg(flag: string, dflt: string): string {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 && process.argv[idx + 1] ? process.argv[idx + 1]! : dflt;
}

const N = Number(getArg('--n', '3'));
const REGION = getArg('--region', 'us-south-2');
const TYPE = getArg('--type', 'gpu_1x_h100_sxm5');
const FS_NAME = getArg('--fs', `kiki-image-${REGION}`);
const TIMEOUT_MS = 30 * 60_000;
const SSH_KEY_PATH = resolve(homedir(), '.ssh', 'id_ed25519');

const client = requireClient();

async function sshUptime(ip: string): Promise<string | null> {
  try {
    const { stdout } = await execFileP(
      'ssh',
      [
        '-i', SSH_KEY_PATH,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'ConnectTimeout=8',
        '-o', 'BatchMode=yes',
        `ubuntu@${ip}`,
        'uptime -s',
      ],
      { timeout: 15_000 },
    );
    return stdout.trim();
  } catch {
    return null;
  }
}

interface ProbeResult {
  name: string;
  launchAcceptedAt: string;
  activeAfterS?: number;
  ipAfterS?: number;
  sshAfterS?: number;
  kernelBootAfterS?: number; // uptime -s minus launch accept — the provisioning window
  error?: string;
}

async function probeOne(i: number, keyName: string): Promise<ProbeResult> {
  const name = `kiki-boottest-${Date.now()}-${i}`;
  const t0 = Date.now();
  const res: ProbeResult = { name, launchAcceptedAt: new Date().toISOString() };
  let id: string | undefined;
  try {
    [id] = await launchWithRetry(
      client,
      {
        region_name: REGION,
        instance_type_name: TYPE,
        ssh_key_names: [keyName],
        file_system_names: [FS_NAME],
        name,
        image: { family: 'lambda-stack-24-04' },
      },
      5,
      undefined,
      (m) => console.log(`[${name}] ${m}`),
    );
    if (!id) throw new Error('no instance id returned');
    res.launchAcceptedAt = new Date().toISOString();
    const launchMs = Date.now();
    console.log(`[${name}] launch accepted id=${id} at ${res.launchAcceptedAt}`);

    let ip: string | undefined;
    for (;;) {
      if (Date.now() - launchMs > TIMEOUT_MS) throw new Error('timed out');
      const inst = await client.getInstance(id);
      if (inst.status === 'active' && res.activeAfterS === undefined) {
        res.activeAfterS = Math.round((Date.now() - launchMs) / 1000);
        console.log(`[${name}] status=active after ${res.activeAfterS}s`);
      }
      if (inst.ip && res.ipAfterS === undefined) {
        ip = inst.ip;
        res.ipAfterS = Math.round((Date.now() - launchMs) / 1000);
        console.log(`[${name}] ip=${ip} after ${res.ipAfterS}s`);
      }
      if (ip) {
        const up = await sshUptime(ip);
        if (up) {
          res.sshAfterS = Math.round((Date.now() - launchMs) / 1000);
          // uptime -s is in the instance's local (UTC) clock
          const kernelBootMs = Date.parse(`${up.replace(' ', 'T')}Z`);
          res.kernelBootAfterS = Math.round((kernelBootMs - launchMs) / 1000);
          console.log(
            `[${name}] ssh up after ${res.sshAfterS}s; kernel booted at +${res.kernelBootAfterS}s (uptime -s = ${up})`,
          );
          break;
        }
      }
      await sleep(5000);
    }
  } catch (err) {
    res.error = (err as Error).message;
    console.log(`[${name}] ERROR: ${res.error}`);
  } finally {
    if (id) {
      await client.terminate([id]).catch((e: Error) => console.log(`[${name}] terminate failed: ${e.message}`));
      console.log(`[${name}] terminated`);
    }
  }
  return res;
}

const keys = await client.listSshKeys();
const keyName = keys[0]?.name;
if (!keyName) throw new Error('no SSH key on the Lambda account');

console.log(`[probe] ${N}× ${TYPE} in ${REGION} (fs=${FS_NAME}); timeout ${TIMEOUT_MS / 60000} min each`);
const results: ProbeResult[] = [];
const inFlight: Promise<void>[] = [];
for (let i = 0; i < N; i++) {
  inFlight.push(probeOne(i, keyName).then((r) => void results.push(r)));
  await sleep(15_000); // account-wide launch spacing
}
await Promise.all(inFlight);

console.log('\n=== RESULTS ===');
console.log(JSON.stringify(results, null, 2));
