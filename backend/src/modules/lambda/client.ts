/**
 * Minimal Lambda Cloud (lambda.ai) REST client.
 *
 * Shared by the runtime dev-pool orchestrator (modules/lambda/devPool.ts) and
 * the ops scripts (backend/scripts/lambda/*). Pure client — no env loading;
 * callers construct it with an API key.
 *
 * API reference: https://cloud.lambda.ai/api/v1/openapi.json (v1.10.0).
 * Auth: `Authorization: Bearer <LAMBDA_API_KEY>`.
 * Rate limits (per Lambda docs): ~1 req/s generally; POST /instance-operations/launch
 * is 1 per 12 s / 5 per minute — do not burst-launch.
 *
 * Operational findings baked into this module (measured 2026-07-15, see
 * documents/plans/lambda-image-provider.md):
 * - The capacity API listing a type does NOT mean a launch will succeed
 *   seconds later — retry the launch itself (launchWithRetry); a successful
 *   launch IS the capacity reservation.
 * - `status: active` lags real instance readiness by 27–62 s. Never gate on
 *   it; probe the app's own /health from the moment `ip` is non-null.
 */

const BASE = 'https://cloud.lambda.ai/api/v1';

export interface InstanceTypeSpecs {
  vcpus: number;
  memory_gib: number;
  storage_gib: number;
  gpus: number;
}

export interface InstanceTypeEntry {
  instance_type: {
    name: string;
    description: string;
    gpu_description: string;
    price_cents_per_hour: number;
    specs: InstanceTypeSpecs;
  };
  regions_with_capacity_available: Array<{ name: string; description: string }>;
}

export interface LambdaInstance {
  id: string;
  name: string | null;
  ip: string | null;
  private_ip: string | null;
  status: 'booting' | 'active' | 'unhealthy' | 'terminating' | 'terminated' | 'preempted';
  ssh_key_names: string[];
  file_system_names: string[];
  region: { name: string; description: string };
  instance_type: InstanceTypeEntry['instance_type'];
  hostname: string | null;
  jupyter_url: string | null;
}

export interface SshKey {
  id: string;
  name: string;
  public_key: string;
}

export interface Filesystem {
  id: string;
  name: string;
  mount_point: string;
  created: string;
  region: { name: string; description: string };
  is_in_use: boolean;
  bytes_used?: number;
}

export interface FirewallRule {
  protocol: 'tcp' | 'udp' | 'icmp' | 'all';
  port_range?: [number, number];
  source_network: string;
  description: string;
}

export interface LaunchRequest {
  region_name: string;
  instance_type_name: string;
  ssh_key_names: [string];
  file_system_names?: string[];
  name?: string;
  hostname?: string;
  image?: { id: string } | { family: string };
  user_data?: string;
}

export class LambdaApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly suggestion?: string,
  ) {
    super(message);
  }
}

export class LambdaClient {
  constructor(private readonly apiKey: string) {}

  private async req<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await fetch(`${BASE}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const json = (await res.json().catch(() => ({}))) as {
      data?: T;
      error?: { code: string; message: string; suggestion?: string };
    };
    if (!res.ok || json.error) {
      const e = json.error ?? { code: `http/${res.status}`, message: res.statusText };
      throw new LambdaApiError(res.status, e.code, e.message, e.suggestion);
    }
    return json.data as T;
  }

  /** `regions_with_capacity_available` is the pre-launch capacity probe
   * (inherently racy — still handle insufficient-capacity on launch). */
  listInstanceTypes(): Promise<Record<string, InstanceTypeEntry>> {
    return this.req('GET', '/instance-types');
  }

  listInstances(): Promise<LambdaInstance[]> {
    return this.req('GET', '/instances');
  }

  getInstance(id: string): Promise<LambdaInstance> {
    return this.req('GET', `/instances/${id}`);
  }

  /** Launch endpoint is rate-limited to 1/12s. Returns instance IDs. */
  async launch(reqBody: LaunchRequest): Promise<string[]> {
    const data = await this.req<{ instance_ids: string[] }>(
      'POST',
      '/instance-operations/launch',
      reqBody,
    );
    return data.instance_ids;
  }

  async terminate(ids: string[]): Promise<LambdaInstance[]> {
    const data = await this.req<{ terminated_instances: LambdaInstance[] }>(
      'POST',
      '/instance-operations/terminate',
      { instance_ids: ids },
    );
    return data.terminated_instances;
  }

  listSshKeys(): Promise<SshKey[]> {
    return this.req('GET', '/ssh-keys');
  }

  addSshKey(name: string, publicKey: string): Promise<SshKey> {
    return this.req('POST', '/ssh-keys', { name, public_key: publicKey });
  }

  listFilesystems(): Promise<Filesystem[]> {
    return this.req('GET', '/file-systems');
  }

  createFilesystem(name: string, regionName: string): Promise<Filesystem> {
    return this.req('POST', '/filesystems', { name, region: regionName });
  }

  /** Delete a filesystem that no instance has attached (verified 2026-09-12:
   * `DELETE /filesystems/{id}` → 200 `{deleted_ids}`). */
  deleteFilesystem(id: string): Promise<{ deleted_ids: string[] }> {
    return this.req('DELETE', `/filesystems/${id}`);
  }

  listFirewallRules(): Promise<FirewallRule[]> {
    return this.req('GET', '/firewall-rules');
  }

  replaceFirewallRules(rules: FirewallRule[]): Promise<FirewallRule[]> {
    return this.req('PUT', '/firewall-rules', { data: rules });
  }

  /** Idempotently ensure an inbound TCP port is open account-wide.
   * Merges with existing rules (GET → append → PUT) since PUT replaces. */
  async ensureInboundTcpPort(port: number, description: string): Promise<void> {
    const rules = await this.listFirewallRules();
    const exists = rules.some(
      (r) =>
        (r.protocol === 'tcp' || r.protocol === 'all') &&
        r.port_range &&
        r.port_range[0] <= port &&
        port <= r.port_range[1] &&
        r.source_network === '0.0.0.0/0',
    );
    if (exists) return;
    await this.replaceFirewallRules([
      ...rules,
      { protocol: 'tcp', port_range: [port, port], source_network: '0.0.0.0/0', description },
    ]);
  }
}

export const lambdaSleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** fetch/undici failures worth retrying: DNS, reset, timeout, refused. */
export function isTransientNetworkError(e: unknown): boolean {
  if (!(e instanceof Error)) return false;
  if (e instanceof LambdaApiError) return e.status >= 500;
  const cause = (e as { cause?: { code?: string } }).cause;
  const code = cause?.code ?? '';
  return (
    /fetch failed|network|socket/i.test(e.message) ||
    ['ENOTFOUND', 'EAI_AGAIN', 'ETIMEDOUT', 'ECONNRESET', 'ECONNREFUSED', 'UND_ERR_CONNECT_TIMEOUT'].includes(code)
  );
}

/**
 * Launch, retrying on `insufficient-capacity` and transient network errors
 * every 15s until the deadline. 15s respects the 1-per-12s launch rate limit.
 * `onAttempt` fires right before each try (e.g. to reset a timing baseline).
 */
// ── account-wide launch spacing ──────────────────────────────────────────
// Lambda's launch endpoint is rate-limited (~1 call/12s per ACCOUNT). One
// retry loop at 15s cadence never trips it — but the image and video pools
// retry CONCURRENTLY, and two interleaved 15s loops average ~7.5s between
// launch calls → 429 storms that killed both pools' capacity searches
// (observed in prod 2026-07-18). All launch attempts in this process gate
// through one timestamp so calls stay ≥13s apart regardless of pool count.
const MIN_LAUNCH_SPACING_MS = 13_000;
let launchGate: Promise<void> = Promise.resolve();
let lastLaunchCallMs = 0;
function spacedLaunchSlot(spacingMs: number): Promise<void> {
  const slot = launchGate.then(async () => {
    const wait = lastLaunchCallMs + spacingMs - Date.now();
    if (wait > 0) await lambdaSleep(wait);
    lastLaunchCallMs = Date.now();
  });
  // Chain regardless of outcome so one failure never wedges the gate.
  launchGate = slot.catch(() => {});
  return slot;
}

/** One spaced launch attempt (account-wide rate-limit gate applied).
 * Throws on failure; classify with isRetryableLaunchError. */
export async function spacedLaunch(
  client: LambdaClient,
  req: LaunchRequest,
  spacingMs: number = MIN_LAUNCH_SPACING_MS,
): Promise<string[]> {
  await spacedLaunchSlot(spacingMs);
  return client.launch(req);
}

/** Errors worth moving on from (next region/type or retry later): capacity
 * misses, the account-wide launch rate limit, transient network. Anything
 * else (auth, quota, malformed request) should surface. */
export function isRetryableLaunchError(e: unknown): boolean {
  if (e instanceof LambdaApiError && /insufficient-capacity/.test(e.code)) return true;
  if (e instanceof LambdaApiError && e.status === 429) return true;
  return isTransientNetworkError(e);
}

export async function launchWithRetry(
  client: LambdaClient,
  req: LaunchRequest,
  retryMins: number,
  onAttempt?: () => void,
  log: (msg: string) => void = console.log,
  /** Override the account-wide launch spacing (tests use 0 — a fake cloud
   * has no rate limit). */
  spacingMs: number = MIN_LAUNCH_SPACING_MS,
): Promise<string[]> {
  const deadline = Date.now() + retryMins * 60_000;
  for (;;) {
    onAttempt?.();
    try {
      await spacedLaunchSlot(spacingMs);
      return await client.launch(req);
    } catch (e) {
      const capacityMiss = e instanceof LambdaApiError && /insufficient-capacity/.test(e.code);
      // 429 = we (or a concurrent retry loop) outpaced the account-wide
      // launch rate limit — transient by definition, retry like capacity.
      const rateLimited = e instanceof LambdaApiError && e.status === 429;
      const transient = isTransientNetworkError(e);
      if ((capacityMiss || rateLimited || transient) && Date.now() < deadline) {
        log(
          capacityMiss
            ? `[launch] insufficient capacity for ${req.instance_type_name} in ${req.region_name} — retrying in 15s`
            : rateLimited
              ? `[launch] launch API rate-limited (429) — retrying in 15s`
              : `[launch] transient network error (${(e as Error).message}) — retrying in 15s`,
        );
        await lambdaSleep(15_000);
        continue;
      }
      throw e;
    }
  }
}

/** Launch a SETUP instance with the pool filesystem attached, without ever
 * leaving an EMPTY filesystem sitting unattached. The pool sweep
 * (instancePool.regionsWithFilesystem) treats "filesystem exists and no
 * foreign instance is attached" as populated — so a filesystem created up
 * front and then parked for an hour of capacity retries is a trap: the pool
 * wins that cell first, boots into nothing and stalls 25 min (nearly
 * happened 2026-09-12 in us-south-3). Here the filesystem is created only
 * once the cell advertises capacity, immediately before the launch, and is
 * deleted again if the launch still misses. A filesystem that already
 * exists (re-run) is used as-is. */
export async function launchSetupWithFilesystem(
  client: LambdaClient,
  opts: {
    region: string;
    type: string;
    fsName: string;
    name: string;
    keyName: string;
    imageFamily: string;
    retryMins: number;
    log?: (msg: string) => void;
  },
): Promise<string[]> {
  const log = opts.log ?? console.log;
  const startedMs = Date.now();
  const deadline = startedMs + opts.retryMins * 60_000;
  log(`[launch] ${opts.type}@${opts.region}: will hunt until ${new Date(deadline).toISOString()} (retryMins=${opts.retryMins})`);
  for (;;) {
    // Poll phase: an API blip here must not kill an hour-long wait.
    let existing: Filesystem | undefined;
    let advertised = true;
    try {
      existing = (await client.listFilesystems()).find(
        (f) => f.name === opts.fsName && f.region.name === opts.region,
      );
      if (!existing) {
        const types = await client.listInstanceTypes();
        advertised = (types[opts.type]?.regions_with_capacity_available ?? []).some((r) => r.name === opts.region);
      }
    } catch (e) {
      if (!isTransientNetworkError(e) && !(e instanceof LambdaApiError && e.status === 429)) throw e;
      log(`[launch] API poll failed transiently (${(e as Error).message.split('\n')[0]}) — retrying in 15s`);
      await lambdaSleep(15_000);
      continue;
    }
    if (!existing && !advertised) {
      if (Date.now() > deadline) {
        throw new Error(
          `no advertised ${opts.type} capacity in ${opts.region} within ${opts.retryMins} min (hunted ${Math.round((Date.now() - startedMs) / 60_000)} min)`,
        );
      }
      log(`[launch] ${opts.type} not advertised in ${opts.region} — filesystem not created yet; polling in 15s`);
      await lambdaSleep(15_000);
      continue;
    }
    let createdId: string | undefined;
    if (!existing) {
      const created = await client.createFilesystem(opts.fsName, opts.region);
      createdId = created.id;
      log(`[launch] created filesystem ${opts.fsName} in ${opts.region} (capacity advertised — launching now)`);
    }
    try {
      await spacedLaunchSlot(MIN_LAUNCH_SPACING_MS);
      return await client.launch({
        region_name: opts.region,
        instance_type_name: opts.type,
        ssh_key_names: [opts.keyName],
        file_system_names: [opts.fsName],
        name: opts.name,
        image: { family: opts.imageFamily },
      } as LaunchRequest);
    } catch (e) {
      if (createdId) {
        try {
          await client.deleteFilesystem(createdId);
          log(`[launch] launch missed — deleted the empty ${opts.fsName} again so the pool never sweeps into it`);
        } catch (delErr) {
          log(`[launch] WARNING: could not delete empty ${opts.fsName}: ${(delErr as Error).message} — delete it by hand`);
        }
      }
      const capacityMiss = e instanceof LambdaApiError && /insufficient-capacity/.test(e.code);
      const rateLimited = e instanceof LambdaApiError && e.status === 429;
      if ((capacityMiss || rateLimited || isTransientNetworkError(e)) && Date.now() < deadline) {
        log(`[launch] ${capacityMiss ? 'insufficient capacity' : rateLimited ? 'rate-limited (429)' : 'transient error'} for ${opts.type} in ${opts.region} — retrying in 15s`);
        await lambdaSleep(15_000);
        continue;
      }
      throw e;
    }
  }
}
