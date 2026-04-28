/**
 * Thin async wrapper around RunPod's GraphQL API for pod lifecycle management.
 * Used by orchestrator.ts to provision, monitor, and terminate per-session
 * pods. All calls are authenticated with RUNPOD_API_KEY from config.
 */

import { config } from '../../config/index.js';

const API_URL = () => `https://api.runpod.io/graphql?api_key=${config.RUNPOD_API_KEY}`;

interface GraphQLResponse<T> {
  data?: T;
  errors?: Array<{ message: string }>;
}

// RunPod's catch-all transient error. They literally say "Please try again
// later" so we honor that — short retry with backoff before surfacing.
const TRANSIENT_RUNPOD_PHRASE = /something went wrong\. please try again later/i;

async function gql<T>(query: string, opts: { retryTransient?: boolean } = {}): Promise<T> {
  const maxAttempts = opts.retryTransient ? 3 : 1;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const res = await fetch(API_URL(), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query }),
    });
    if (!res.ok) {
      throw new Error(`RunPod API HTTP ${res.status}: ${await res.text()}`);
    }
    const body = (await res.json()) as GraphQLResponse<T>;
    if (body.errors && body.errors.length > 0) {
      const msg = body.errors.map((e) => e.message).join('; ');
      if (attempt < maxAttempts && TRANSIENT_RUNPOD_PHRASE.test(msg)) {
        await new Promise((r) => setTimeout(r, 1000 * attempt));
        continue;
      }
      throw new Error(`RunPod API error: ${msg}`);
    }
    if (!body.data) {
      throw new Error('RunPod API returned no data');
    }
    return body.data;
  }
  throw new Error('gql retry loop exhausted without resolution');
}

export interface SpotBidInfo {
  minimumBidPrice: number;
  stockStatus: 'High' | 'Medium' | 'Low' | 'None' | string;
}

/**
 * Returns the current minimum bid price and stock availability for a GPU type
 * on secure cloud. NOTE: the 5090 has no spot tier on community cloud, so we
 * always query secure. The `lowestPrice` RunPod query returns null for
 * `minimumBidPrice` if you don't pass `secureCloud: true`.
 *
 * When `dataCenterId` is passed, returns stock for just that DC (null if the
 * DC has no 5090 capacity at the moment). Used by the network-volume path to
 * pick a DC where both a populated volume AND spot capacity exist.
 */
export async function getSpotBid(
  gpuTypeId: string,
  opts: { dataCenterId?: string } = {},
): Promise<SpotBidInfo> {
  const dcField = opts.dataCenterId ? `, dataCenterId: "${opts.dataCenterId}"` : '';
  const query = `query {
    gpuTypes(input: { id: "${gpuTypeId}" }) {
      lowestPrice(input: { gpuCount: 1, secureCloud: true${dcField} }) {
        minimumBidPrice
        stockStatus
      }
    }
  }`;
  const data = await gql<{
    gpuTypes: Array<{ lowestPrice: { minimumBidPrice: number | null; stockStatus: string | null } }>;
  }>(query);
  const lp = data.gpuTypes[0]?.lowestPrice;
  if (!lp || lp.minimumBidPrice == null) {
    const where = opts.dataCenterId ? ` in ${opts.dataCenterId}` : ' in secure cloud';
    throw new Error(`No spot pricing available for ${gpuTypeId}${where}`);
  }
  return {
    minimumBidPrice: lp.minimumBidPrice,
    stockStatus: lp.stockStatus ?? 'Unknown',
  };
}

export interface CreateSpotPodInput {
  name: string;
  imageName: string;
  gpuTypeId: string;
  bidPerGpu: number;
  ports?: string;
  containerDiskInGb?: number;
  minMemoryInGb?: number;
  minVcpuCount?: number;
  /** RunPod container registry credential ID for authenticated Docker Hub pulls.
   * Without this, pulls are anonymous and hit Docker Hub's 100-pull/6hr/IP rate limit. */
  containerRegistryAuthId?: string;
  /** Pin placement to this datacenter. Required when networkVolumeId is set
   * (volumes are DC-locked). */
  dataCenterId?: string;
  /** Attach this network volume at /workspace. Pre-populated with FLUX weights
   * (and /workspace/venv + /workspace/app — see scripts/sync-flux-app.ts) so
   * the server skips model download + has deps ready. */
  networkVolumeId?: string;
  /** Container CMD override. Run this at pod boot instead of the image's
   * default CMD. Used by the volume-entrypoint flow to exec our server from
   * /workspace/app without a custom image. */
  dockerArgs?: string;
  /** Environment variables set at pod-create time. Visible in RunPod UI. */
  env?: Array<{ key: string; value: string }>;
}

export interface PodCreateResult {
  id: string;
  costPerHr: number;
}

// Render optional GraphQL input fields as `, fieldName: value` suffixes.
// `JSON.stringify` gives us GraphQL-safe string escaping (quotes, backslashes,
// newlines). GraphQL's string literal grammar is close enough to JSON's that
// this round-trips correctly for our inputs.
function renderDockerArgsField(dockerArgs: string | undefined): string {
  if (!dockerArgs) return '';
  return `, dockerArgs: ${JSON.stringify(dockerArgs)}`;
}

function renderEnvField(env: Array<{ key: string; value: string }> | undefined): string {
  if (!env || env.length === 0) return '';
  const entries = env.map((e) => `{ key: ${JSON.stringify(e.key)}, value: ${JSON.stringify(e.value)} }`);
  return `, env: [${entries.join(', ')}]`;
}

export interface CreateOnDemandPodInput {
  name: string;
  imageName: string;
  gpuTypeId: string;
  /** SECURE is Blackwell-reliable (newest drivers). COMMUNITY is cheaper
   * (~$0.69/hr vs $0.99/hr) but older driver fleet → NVFP4 compat risk. */
  cloudType?: 'SECURE' | 'COMMUNITY';
  ports?: string;
  containerDiskInGb?: number;
  minMemoryInGb?: number;
  minVcpuCount?: number;
  containerRegistryAuthId?: string;
  dataCenterId?: string;
  networkVolumeId?: string;
  /** See CreateSpotPodInput.dockerArgs. */
  dockerArgs?: string;
  /** See CreateSpotPodInput.env. */
  env?: Array<{ key: string; value: string }>;
}

/**
 * On-demand equivalent of `createSpotPod` — uses `podFindAndDeploy` so the pod
 * is billed at on-demand rate and will not be preempted by capacity shifts.
 * Called by the orchestrator as a fallback when spot capacity is exhausted.
 */
export async function createOnDemandPod(input: CreateOnDemandPodInput): Promise<PodCreateResult> {
  const {
    name,
    imageName,
    gpuTypeId,
    cloudType = 'SECURE',
    ports = '8766/http,22/tcp',
    containerDiskInGb = 40,
    minMemoryInGb = 16,
    minVcpuCount = 4,
    containerRegistryAuthId,
    dataCenterId,
    networkVolumeId,
    dockerArgs,
    env,
  } = input;
  const authField = containerRegistryAuthId
    ? `, containerRegistryAuthId: "${containerRegistryAuthId}"`
    : '';
  const dcField = dataCenterId ? `, dataCenterId: "${dataCenterId}"` : '';
  // When a network volume is attached, RunPod requires an explicit mount path
  // or container create fails with "field Target must not be empty". We always
  // mount at /workspace.
  const volField = networkVolumeId
    ? `, networkVolumeId: "${networkVolumeId}", volumeMountPath: "/workspace"`
    : '';
  const dockerArgsField = renderDockerArgsField(dockerArgs);
  const envField = renderEnvField(env);
  const query = `mutation {
    podFindAndDeployOnDemand(input: {
      name: "${name}",
      imageName: "${imageName}",
      gpuTypeId: "${gpuTypeId}",
      gpuCount: 1,
      cloudType: ${cloudType},
      volumeInGb: 0,
      containerDiskInGb: ${containerDiskInGb},
      minMemoryInGb: ${minMemoryInGb},
      minVcpuCount: ${minVcpuCount},
      ports: "${ports}",
      startSsh: true${authField}${dcField}${volField}${dockerArgsField}${envField}
    }) { id desiredStatus costPerHr }
  }`;
  const data = await gql<{ podFindAndDeployOnDemand: { id: string; costPerHr: number } | null }>(query, { retryTransient: true });
  if (!data.podFindAndDeployOnDemand) {
    throw new Error(`RunPod returned no pod (on-demand ${cloudType.toLowerCase()} capacity also unavailable)`);
  }
  return data.podFindAndDeployOnDemand;
}

/**
 * True if the error message looks like a RunPod capacity-exhaustion signal,
 * which is distinct from auth errors, 500s, or user bugs. Used by the
 * orchestrator to decide whether to fall through from spot to on-demand.
 */
export function isCapacityError(err: unknown): boolean {
  const msg = (err instanceof Error ? err.message : String(err)).toLowerCase();
  return (
    msg.includes('no longer any instances available') ||
    msg.includes('no instances available') ||
    msg.includes('no pod (spot capacity likely unavailable)') ||
    msg.includes('no spot pricing available') ||
    msg.includes('does not have the resources') ||
    msg.includes('stock')
  );
}

export async function createSpotPod(input: CreateSpotPodInput): Promise<PodCreateResult> {
  const {
    name,
    imageName,
    gpuTypeId,
    bidPerGpu,
    ports = '8766/http,22/tcp',
    containerDiskInGb = 40,
    minMemoryInGb = 16,
    minVcpuCount = 4,
    containerRegistryAuthId,
    dataCenterId,
    networkVolumeId,
    dockerArgs,
    env,
  } = input;
  const authField = containerRegistryAuthId
    ? `, containerRegistryAuthId: "${containerRegistryAuthId}"`
    : '';
  const dcField = dataCenterId ? `, dataCenterId: "${dataCenterId}"` : '';
  // When a network volume is attached, RunPod requires an explicit mount path
  // or container create fails with "field Target must not be empty". We always
  // mount at /workspace.
  const volField = networkVolumeId
    ? `, networkVolumeId: "${networkVolumeId}", volumeMountPath: "/workspace"`
    : '';
  const dockerArgsField = renderDockerArgsField(dockerArgs);
  const envField = renderEnvField(env);
  const query = `mutation {
    podRentInterruptable(input: {
      name: "${name}",
      imageName: "${imageName}",
      gpuTypeId: "${gpuTypeId}",
      gpuCount: 1,
      bidPerGpu: ${bidPerGpu},
      cloudType: SECURE,
      volumeInGb: 0,
      containerDiskInGb: ${containerDiskInGb},
      minMemoryInGb: ${minMemoryInGb},
      minVcpuCount: ${minVcpuCount},
      ports: "${ports}",
      startSsh: true${authField}${dcField}${volField}${dockerArgsField}${envField}
    }) { id desiredStatus costPerHr }
  }`;
  const data = await gql<{ podRentInterruptable: { id: string; costPerHr: number } | null }>(query, { retryTransient: true });
  if (!data.podRentInterruptable) {
    throw new Error('RunPod returned no pod (spot capacity likely unavailable)');
  }
  return data.podRentInterruptable;
}

export interface PodRuntime {
  id: string;
  desiredStatus: string;
  runtime: {
    uptimeInSeconds: number;
    ports: Array<{
      ip: string;
      isIpPublic: boolean;
      privatePort: number;
      publicPort: number;
      type: string;
    }>;
  } | null;
  machine: { dataCenterId: string } | null;
}

export async function getPod(podId: string): Promise<PodRuntime | null> {
  const query = `query {
    pod(input: { podId: "${podId}" }) {
      id
      desiredStatus
      machine { dataCenterId }
      runtime {
        uptimeInSeconds
        ports { ip isIpPublic privatePort publicPort type }
      }
    }
  }`;
  const data = await gql<{ pod: PodRuntime | null }>(query);
  return data.pod;
}

export async function terminatePod(podId: string): Promise<void> {
  const query = `mutation { podTerminate(input: { podId: "${podId}" }) }`;
  await gql(query);
}

export interface PodSummary {
  id: string;
  name: string;
  desiredStatus: string;
  /** Null while the container is still starting up. Once the pod is live,
   * `uptimeInSeconds` counts from runtime initialization (not pod creation). */
  runtime: { uptimeInSeconds: number } | null;
}

/**
 * Returns all pods on the account whose name starts with the given prefix.
 * Used by the reconcile step to find orphaned per-session pods.
 */
export async function listPodsByPrefix(prefix: string): Promise<PodSummary[]> {
  const query = `query { myself { pods { id name desiredStatus runtime { uptimeInSeconds } } } }`;
  const data = await gql<{ myself: { pods: PodSummary[] } }>(query);
  return data.myself.pods.filter((p) => p.name.startsWith(prefix));
}

export interface PodCostInfo {
  id: string;
  name: string;
  desiredStatus: string;
  costPerHr: number;
  runtime: { uptimeInSeconds: number } | null;
}

/**
 * Like `listPodsByPrefix` but returns `costPerHr` and `runtime.uptimeInSeconds`
 * for cost monitoring. Used by `costMonitor.ts` to compute burn rate without
 * depending on orchestrator in-memory state.
 */
export async function listPodsWithCost(prefix: string): Promise<PodCostInfo[]> {
  const query = `query { myself { pods { id name desiredStatus costPerHr runtime { uptimeInSeconds } } } }`;
  const data = await gql<{ myself: { pods: PodCostInfo[] } }>(query);
  return data.myself.pods.filter((p) => p.name.startsWith(prefix));
}
