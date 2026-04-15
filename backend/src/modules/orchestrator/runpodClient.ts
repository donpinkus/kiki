/**
 * Thin async wrapper around RunPod's GraphQL API for pod lifecycle management.
 * Exactly mirrors the patterns used in .github/workflows/deploy-flux-klein.yml
 * so that behavior is identical to the manual-deploy flow we already know works.
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
 * on secure cloud. The 5090 has no spot tier on community cloud, so we always
 * query secure — see memory: reference_runpod_spot_api.md.
 */
export async function getSpotBid(gpuTypeId: string): Promise<SpotBidInfo> {
  const query = `query {
    gpuTypes(input: { id: "${gpuTypeId}" }) {
      lowestPrice(input: { gpuCount: 1, secureCloud: true }) {
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
    throw new Error(`No spot pricing available for ${gpuTypeId} in secure cloud`);
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
}

export interface PodCreateResult {
  id: string;
  costPerHr: number;
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
  } = input;
  const authField = containerRegistryAuthId
    ? `, containerRegistryAuthId: "${containerRegistryAuthId}"`
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
      startSsh: true${authField}
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
