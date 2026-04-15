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

async function gql<T>(query: string): Promise<T> {
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
    throw new Error(`RunPod API error: ${body.errors.map((e) => e.message).join('; ')}`);
  }
  if (!body.data) {
    throw new Error('RunPod API returned no data');
  }
  return body.data;
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
   * so the server skips the 2-3 min model download on cold start. */
  networkVolumeId?: string;
}

export interface PodCreateResult {
  id: string;
  costPerHr: number;
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
  } = input;
  const authField = containerRegistryAuthId
    ? `, containerRegistryAuthId: "${containerRegistryAuthId}"`
    : '';
  const dcField = dataCenterId ? `, dataCenterId: "${dataCenterId}"` : '';
  // When a network volume is attached, RunPod requires an explicit mount path
  // or container create fails with "field Target must not be empty". We always
  // mount at /workspace — the Dockerfile's HF_HOME points into it.
  const volField = networkVolumeId
    ? `, networkVolumeId: "${networkVolumeId}", volumeMountPath: "/workspace"`
    : '';
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
      startSsh: true${authField}${dcField}${volField}
    }) { id desiredStatus costPerHr }
  }`;
  const data = await gql<{ podFindAndDeployOnDemand: { id: string; costPerHr: number } | null }>(query);
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
  } = input;
  const authField = containerRegistryAuthId
    ? `, containerRegistryAuthId: "${containerRegistryAuthId}"`
    : '';
  const dcField = dataCenterId ? `, dataCenterId: "${dataCenterId}"` : '';
  // When a network volume is attached, RunPod requires an explicit mount path
  // or container create fails with "field Target must not be empty". We always
  // mount at /workspace — the Dockerfile's HF_HOME points into it.
  const volField = networkVolumeId
    ? `, networkVolumeId: "${networkVolumeId}", volumeMountPath: "/workspace"`
    : '';
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
      startSsh: true${authField}${dcField}${volField}
    }) { id desiredStatus costPerHr }
  }`;
  const data = await gql<{ podRentInterruptable: { id: string; costPerHr: number } | null }>(query);
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
}

/**
 * Returns all pods on the account whose name starts with the given prefix.
 * Used by the startup reconcile step to find orphaned per-session pods.
 */
export async function listPodsByPrefix(prefix: string): Promise<PodSummary[]> {
  const query = `query { myself { pods { id name desiredStatus } } }`;
  const data = await gql<{ myself: { pods: PodSummary[] } }>(query);
  return data.myself.pods.filter((p) => p.name.startsWith(prefix));
}
