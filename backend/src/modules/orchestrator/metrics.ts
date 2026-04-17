/**
 * In-process metrics: counters + fixed-bucket histograms.
 *
 * No external dependencies. Counters are since-boot (reset on deploy).
 * Histograms use fixed buckets with cumulative counts for percentile estimation.
 * Exposed via /v1/ops/metrics as JSON.
 *
 * Usage:
 *   incrementCounter('provision_start_total');
 *   incrementCounter('provision_failed_total', { category: 'ssh_timeout' });
 *   observeHistogram('provision_total_ms', 142000);
 *   const snap = snapshot();  // called by ops route
 */

// ────────────────────────────────────────────────────────────────────────────
// Counters
// ────────────────────────────────────────────────────────────────────────────

const counters = new Map<string, number>();

function counterKey(name: string, labels?: Record<string, string>): string {
  if (!labels || Object.keys(labels).length === 0) return name;
  const sorted = Object.keys(labels).sort().map((k) => `${k}=${labels[k]}`).join(',');
  return `${name}{${sorted}}`;
}

export function incrementCounter(name: string, labels?: Record<string, string>): void {
  const key = counterKey(name, labels);
  counters.set(key, (counters.get(key) ?? 0) + 1);
}

function getCounterGroup(prefix: string): Record<string, number> | number {
  const result: Record<string, number> = {};
  let plain = 0;
  let hasLabels = false;
  for (const [key, val] of counters) {
    if (key === prefix) {
      plain = val;
    } else if (key.startsWith(`${prefix}{`)) {
      hasLabels = true;
      const labelStr = key.slice(prefix.length + 1, -1);
      const labelVal = labelStr.split(',').map((s) => s.split('=')[1]).join(',');
      result[labelVal] = val;
    }
  }
  if (hasLabels) return result;
  return plain;
}

// ────────────────────────────────────────────────────────────────────────────
// Histograms
// ────────────────────────────────────────────────────────────────────────────

interface HistState {
  buckets: number[];      // upper bounds (ms)
  counts: number[];       // cumulative count per bucket
  sum: number;
  count: number;
}

const histograms = new Map<string, HistState>();

const HISTOGRAM_CONFIGS: Record<string, number[]> = {
  provision_total_ms: [30000, 60000, 90000, 120000, 180000, 240000, 300000, 420000, 600000],
  pod_creation_ms: [2000, 5000, 10000, 15000, 30000, 60000],
  container_pull_ms: [10000, 30000, 60000, 120000, 180000, 300000, 600000],
  health_ready_ms: [5000, 10000, 20000, 30000, 60000, 120000],
  semaphore_wait_ms: [0, 1000, 5000, 15000, 60000, 180000, 600000],
  session_lifetime_ms: [60000, 300000, 600000, 900000, 1800000, 3600000],
  provision_failed_ms: [5000, 30000, 60000, 180000, 600000],
};

function getOrCreateHist(name: string): HistState {
  let h = histograms.get(name);
  if (!h) {
    const buckets = HISTOGRAM_CONFIGS[name] ?? [100, 500, 1000, 5000, 30000, 60000];
    h = { buckets, counts: new Array(buckets.length + 1).fill(0) as number[], sum: 0, count: 0 };
    histograms.set(name, h);
  }
  return h;
}

export function observeHistogram(name: string, ms: number): void {
  const h = getOrCreateHist(name);
  h.sum += ms;
  h.count++;
  for (let i = 0; i < h.buckets.length; i++) {
    if (ms <= h.buckets[i]!) {
      h.counts[i]!++;
      return;
    }
  }
  h.counts[h.buckets.length]!++; // +Inf bucket
}

function percentile(h: HistState, p: number): number | null {
  if (h.count === 0) return null;
  const target = Math.ceil(h.count * p);
  let cumulative = 0;
  for (let i = 0; i < h.buckets.length; i++) {
    cumulative += h.counts[i]!;
    if (cumulative >= target) return h.buckets[i]!;
  }
  return h.buckets[h.buckets.length - 1]! * 1.5; // beyond last bucket
}

function histSnapshot(h: HistState): { p50: number | null; p95: number | null; p99: number | null; avg: number | null; count: number } {
  return {
    p50: percentile(h, 0.5),
    p95: percentile(h, 0.95),
    p99: percentile(h, 0.99),
    avg: h.count > 0 ? Math.round(h.sum / h.count) : null,
    count: h.count,
  };
}

// ────────────────────────────────────────────────────────────────────────────
// Gauges (point-in-time, set externally)
// ────────────────────────────────────────────────────────────────────────────

const gauges = new Map<string, number | Record<string, number>>();

export function setGauge(name: string, value: number | Record<string, number>): void {
  gauges.set(name, value);
}

// ────────────────────────────────────────────────────────────────────────────
// Snapshot (called by /v1/ops/metrics)
// ────────────────────────────────────────────────────────────────────────────

const bootTime = Date.now();

export interface MetricsSnapshot {
  uptimeSeconds: number;
  snapshotAt: string;
  gauges: Record<string, unknown>;
  counters: Record<string, unknown>;
  histograms: Record<string, unknown>;
}

export function snapshot(): MetricsSnapshot {
  const counterNames = new Set<string>();
  for (const key of counters.keys()) {
    counterNames.add(key.split('{')[0]!);
  }

  const counterObj: Record<string, unknown> = {};
  for (const name of counterNames) {
    counterObj[name] = getCounterGroup(name);
  }

  const histObj: Record<string, unknown> = {};
  for (const [name, h] of histograms) {
    histObj[name] = histSnapshot(h);
  }

  const gaugeObj: Record<string, unknown> = {};
  for (const [name, val] of gauges) {
    gaugeObj[name] = val;
  }

  return {
    uptimeSeconds: Math.round((Date.now() - bootTime) / 1000),
    snapshotAt: new Date().toISOString(),
    gauges: gaugeObj,
    counters: counterObj,
    histograms: histObj,
  };
}

// ────────────────────────────────────────────────────────────────────────────
// Failure categorization
// ────────────────────────────────────────────────────────────────────────────

export type FailureCategory =
  | 'spot_capacity'
  | 'pod_create_failed'
  | 'container_pull_timeout'
  | 'ssh_timeout'
  | 'scp_failed'
  | 'setup_failed'
  | 'health_timeout'
  | 'monthly_cap'
  | 'unknown';

export function classifyProvisionError(err: Error): FailureCategory {
  const msg = err.message.toLowerCase();
  if (msg.includes('spot capacity') || msg.includes('capacity exhausted') || msg.includes('no runpod dc')) return 'spot_capacity';
  if (msg.includes('container never started')) return 'container_pull_timeout';
  if (msg.includes('never got ssh')) return 'ssh_timeout';
  if (msg.includes('scp') || msg.includes('scpfiles')) return 'scp_failed';
  if (msg.includes('setup') || msg.includes('setup-flux-klein')) return 'setup_failed';
  if (msg.includes('never became healthy')) return 'health_timeout';
  if (msg.includes('monthly_cap') || msg.includes('cost gate')) return 'monthly_cap';
  if (msg.includes('failed to create') || msg.includes('returned no pod')) return 'pod_create_failed';
  return 'unknown';
}
