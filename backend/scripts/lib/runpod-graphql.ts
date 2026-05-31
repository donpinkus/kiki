/**
 * Thin async wrappers over RunPod GraphQL for ops scripts (DC discovery,
 * volume listing/creation, stock probes).
 *
 * Reads RUNPOD_API_KEY directly from process.env so this can be imported
 * from standalone CLI scripts without triggering full backend config
 * validation (same pattern as runpodClient.ts).
 *
 * For the runtime hot path (orchestrator provisioning), use the
 * fully-retried gql wrapper in src/modules/orchestrator/runpodClient.ts
 * instead — this module's gql() is intentionally minimal.
 */

function apiUrl(): string {
  const key = process.env['RUNPOD_API_KEY'];
  if (!key) {
    throw new Error('RUNPOD_API_KEY required in environment');
  }
  return `https://api.runpod.io/graphql?api_key=${key}`;
}

async function gql<T>(query: string): Promise<T> {
  const res = await fetch(apiUrl(), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  if (!res.ok) {
    throw new Error(`RunPod HTTP ${res.status}: ${await res.text()}`);
  }
  const body = (await res.json()) as { data?: T; errors?: Array<{ message: string }> };
  if (body.errors?.length) {
    throw new Error(`RunPod GraphQL: ${body.errors.map((e) => e.message).join('; ')}`);
  }
  if (!body.data) throw new Error('RunPod GraphQL: no data');
  return body.data;
}

export interface NetworkVolume {
  id: string;
  name: string;
  dataCenterId: string;
  size: number;
}

export async function listNetworkVolumes(): Promise<NetworkVolume[]> {
  const data = await gql<{ myself: { networkVolumes: NetworkVolume[] } }>(
    'query { myself { networkVolumes { id name dataCenterId size } } }',
  );
  return data.myself.networkVolumes;
}

export async function createNetworkVolume(
  name: string,
  dataCenterId: string,
  sizeGb: number,
): Promise<NetworkVolume> {
  const q = `mutation { createNetworkVolume(input: { name: "${name}", dataCenterId: "${dataCenterId}", size: ${sizeGb} }) { id name dataCenterId size } }`;
  const data = await gql<{ createNetworkVolume: NetworkVolume | null }>(q);
  if (!data.createNetworkVolume) {
    throw new Error(`createNetworkVolume returned null for ${name} in ${dataCenterId}`);
  }
  return data.createNetworkVolume;
}

export interface GpuStock {
  /** RunPod stockStatus: 'High' | 'Medium' | 'Low' | 'None' (or null when DC has no allocation at all). */
  stockStatus: string | null;
  /** On-demand price per hour, USD. null when stock is null. */
  uninterruptablePrice: number | null;
}

export async function getGpuStock(
  gpuTypeId: string,
  dataCenterId: string,
): Promise<GpuStock> {
  const q = `query { gpuTypes(input: { id: "${gpuTypeId}" }) { lowestPrice(input: { gpuCount: 1, secureCloud: true, dataCenterId: "${dataCenterId}" }) { stockStatus uninterruptablePrice } } }`;
  const data = await gql<{
    gpuTypes: Array<{ lowestPrice: { stockStatus: string | null; uninterruptablePrice: number | null } | null }>;
  }>(q);
  const lp = data.gpuTypes[0]?.lowestPrice;
  return {
    stockStatus: lp?.stockStatus ?? null,
    uninterruptablePrice: lp?.uninterruptablePrice ?? null,
  };
}

export async function listDataCenters(): Promise<string[]> {
  const data = await gql<{ dataCenters: Array<{ id: string }> }>(
    'query { dataCenters { id } }',
  );
  return data.dataCenters.map((d) => d.id);
}
