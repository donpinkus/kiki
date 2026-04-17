/**
 * Cost monitor — periodic RunPod spend tracking + alerting.
 *
 * Every COST_MONITOR_INTERVAL_MS (default 5 min):
 * - Lists all kiki-session-* pods with costPerHr + uptimeInSeconds
 * - Computes burn rate, rolling 24h spend, oldest pod age
 * - Logs structured tick + checks threshold alerts
 * - Fires Discord/Slack webhook on breaches (with cooldown)
 *
 * Exposes getSnapshot() and getHistory() for the /v1/ops/cost endpoints.
 */

import { timingSafeEqual } from 'node:crypto';
import type { FastifyBaseLogger } from 'fastify';

import { config } from '../../config/index.js';
import { listPodsWithCost, type PodCostInfo } from './runpodClient.js';

// ────────────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────────────

interface PodBreakdown {
  podId: string;
  name: string;
  costPerHr: number;
  ageSeconds: number;
}

export interface CostSnapshot {
  capturedAt: string;
  activePodCount: number;
  currentBurnPerHr: number;
  rolling24hTotal: number;
  oldestPodAgeSeconds: number;
  pods: PodBreakdown[];
  thresholds: {
    maxActivePods: number;
    max24hSpend: number;
    maxMonthlySpend: number;
    maxPodAgeSeconds: number;
  };
  lastAlertAt: string | null;
}

export interface TickEntry {
  timestamp: string;
  burnPerHr: number;
  activePodCount: number;
}

// ────────────────────────────────────────────────────────────────────────────
// Module state
// ────────────────────────────────────────────────────────────────────────────

const POD_PREFIX = 'kiki-session-';
const RING_BUFFER_MAX = 288; // 24h at 5-min intervals

let log: FastifyBaseLogger = console as unknown as FastifyBaseLogger;
let tickTimer: ReturnType<typeof setInterval> | null = null;
let hourlyTimer: ReturnType<typeof setInterval> | null = null;

const ringBuffer: TickEntry[] = [];

// Pod lifecycle thread tracking: podId → Discord thread (channel) ID
const podThreads = new Map<string, string>();
let latestSnapshot: CostSnapshot | null = null;
let consecutiveFailures = 0;
let costGateOpen = true;

// Alert cooldown state
const lastAlertAt = new Map<string, number>();

// Daily rollup tracking
let currentDayUtc = new Date().getUTCDate();
let dayPeakBurnPerHr = 0;
let dayPeakActivePods = 0;
let daySampleCount = 0;

// ────────────────────────────────────────────────────────────────────────────
// Public API
// ────────────────────────────────────────────────────────────────────────────

export function getSnapshot(): CostSnapshot | null {
  return latestSnapshot;
}

export function getHistory(): TickEntry[] {
  return [...ringBuffer];
}

/** Returns false when the monthly spend cap has been tripped. Orchestrator
 * should check this before provisioning. */
export function isCostGateOpen(): boolean {
  return costGateOpen;
}

export function start(logger: FastifyBaseLogger): void {
  log = logger;
  const intervalMs = config.COST_MONITOR_INTERVAL_MS;
  log.info({ intervalMs }, 'Cost monitor started');

  // Run first tick immediately, then on interval
  void tick();
  tickTimer = setInterval(() => void tick(), intervalMs);

  // Hourly digest to Discord
  hourlyTimer = setInterval(() => void sendHourlyDigest(), 3_600_000);
}

export function stop(): void {
  if (tickTimer) { clearInterval(tickTimer); tickTimer = null; }
  if (hourlyTimer) { clearInterval(hourlyTimer); hourlyTimer = null; }
}

// ────────────────────────────────────────────────────────────────────────────
// Pod lifecycle threads (Discord Forum channel)
//
// Each pod gets a thread in the #pod-logs forum channel. The thread is created
// on pod creation and updated with progress messages. This avoids spamming
// the main alerts channel while still giving full visibility.
// ────────────────────────────────────────────────────────────────────────────

interface WebhookResponse {
  id: string;
  channel_id: string;
}

/**
 * Called when a pod is created. Creates a new thread in the forum channel.
 */
export async function notifyPodCreated(event: {
  podId: string;
  podType: string;
  dc?: string;
  costPerHr?: number;
}): Promise<void> {
  const webhookUrl = config.COST_POD_LOG_WEBHOOK_URL || config.COST_ALERT_WEBHOOK_URL;
  if (!webhookUrl) return;

  const cost = event.costPerHr != null ? `$${event.costPerHr.toFixed(2)}/hr` : '?';
  const dc = event.dc ?? 'unknown';
  const shortId = event.podId.slice(0, 12);
  const threadName = `${event.podType === 'spot' ? '🟢' : '🟡'} ${shortId} · ${dc} · ${cost}`;
  const content = `Pod \`${event.podId}\` created\n**Type:** ${event.podType}\n**DC:** ${dc}\n**Cost:** ${cost}`;

  try {
    const res = await fetch(`${webhookUrl}?wait=true`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        content,
        thread_name: threadName,
      }),
      signal: AbortSignal.timeout(10_000),
    });
    if (res.ok) {
      const body = (await res.json()) as WebhookResponse;
      // In a forum channel, the thread ID is the channel_id of the response
      podThreads.set(event.podId, body.channel_id);
    } else {
      log.warn({ status: res.status, podId: event.podId }, 'Pod thread creation failed');
    }
  } catch (err) {
    log.warn({ err: (err as Error).message, podId: event.podId }, 'Pod thread creation failed');
  }
}

/**
 * Called at each provision stage. Posts to the pod's existing thread.
 */
export function notifyPodProgress(podId: string, message: string): void {
  const threadId = podThreads.get(podId);
  if (!threadId) return;

  const webhookUrl = config.COST_POD_LOG_WEBHOOK_URL || config.COST_ALERT_WEBHOOK_URL;
  if (!webhookUrl) return;

  fetch(`${webhookUrl}?thread_id=${threadId}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: message }),
    signal: AbortSignal.timeout(5000),
  }).catch((err) => {
    log.warn({ err: (err as Error).message, podId }, 'Pod progress webhook failed');
  });
}

/**
 * Called when a pod is terminated. Posts final message to thread, cleans up.
 */
export function notifyPodTerminated(podId: string, reason: string): void {
  const threadId = podThreads.get(podId);
  const webhookUrl = config.COST_POD_LOG_WEBHOOK_URL || config.COST_ALERT_WEBHOOK_URL;

  if (threadId && webhookUrl) {
    fetch(`${webhookUrl}?thread_id=${threadId}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: `🔴 **Terminated** — ${reason}` }),
      signal: AbortSignal.timeout(5000),
    }).catch((err) => {
      log.warn({ err: (err as Error).message, podId }, 'Pod terminated webhook failed');
    });
  }

  podThreads.delete(podId);
}

// ────────────────────────────────────────────────────────────────────────────
// Tick
// ────────────────────────────────────────────────────────────────────────────

async function tick(): Promise<void> {
  let pods: PodCostInfo[];
  try {
    pods = await listPodsWithCost(POD_PREFIX);
    consecutiveFailures = 0;
  } catch (err) {
    consecutiveFailures++;
    log.warn(
      { err: (err as Error).message, consecutiveFailures },
      'Cost monitor tick failed',
    );
    if (consecutiveFailures >= 3) {
      void fireAlert('monitor_unhealthy', `Cost monitor failing (${consecutiveFailures} consecutive errors: ${(err as Error).message})`);
      consecutiveFailures = 0; // reset after alert
    }
    return;
  }

  const now = new Date();
  const activePods = pods.filter((p) => p.desiredStatus === 'RUNNING');
  const burnPerHr = activePods.reduce((sum, p) => sum + (p.costPerHr ?? 0), 0);
  const oldestAge = activePods.reduce(
    (max, p) => Math.max(max, p.runtime?.uptimeInSeconds ?? 0),
    0,
  );

  const podBreakdowns: PodBreakdown[] = activePods.map((p) => ({
    podId: p.id,
    name: p.name,
    costPerHr: p.costPerHr ?? 0,
    ageSeconds: p.runtime?.uptimeInSeconds ?? 0,
  }));

  // Ring buffer
  const entry: TickEntry = {
    timestamp: now.toISOString(),
    burnPerHr: Math.round(burnPerHr * 10000) / 10000,
    activePodCount: activePods.length,
  };
  ringBuffer.push(entry);
  if (ringBuffer.length > RING_BUFFER_MAX) ringBuffer.shift();

  // Rolling 24h spend estimate (trapezoidal integration over ring buffer)
  const rolling24h = computeRolling24h();

  // Build snapshot
  latestSnapshot = {
    capturedAt: now.toISOString(),
    activePodCount: activePods.length,
    currentBurnPerHr: entry.burnPerHr,
    rolling24hTotal: Math.round(rolling24h * 100) / 100,
    oldestPodAgeSeconds: oldestAge,
    pods: podBreakdowns,
    thresholds: {
      maxActivePods: config.COST_ALERT_MAX_ACTIVE_PODS,
      max24hSpend: config.COST_ALERT_MAX_24H_SPEND,
      maxMonthlySpend: config.COST_ALERT_MAX_MONTHLY_SPEND,
      maxPodAgeSeconds: config.COST_ALERT_MAX_POD_AGE_SECONDS,
    },
    lastAlertAt: lastAlertTimestamp(),
  };

  // Structured log
  log.info(
    {
      event: 'kiki.cost.tick',
      burnPerHr: entry.burnPerHr,
      activePods: activePods.length,
      oldestPodAgeSec: oldestAge,
      rolling24h: latestSnapshot.rolling24hTotal,
    },
    'Cost tick',
  );

  // Daily rollup check
  dayPeakBurnPerHr = Math.max(dayPeakBurnPerHr, entry.burnPerHr);
  dayPeakActivePods = Math.max(dayPeakActivePods, activePods.length);
  daySampleCount++;
  checkDailyRollup(now);

  // Threshold checks
  if (activePods.length > config.COST_ALERT_MAX_ACTIVE_PODS) {
    void fireAlert(
      'max_active_pods',
      `max_active_pods breached (${activePods.length} > ${config.COST_ALERT_MAX_ACTIVE_PODS})`,
    );
  }
  if (rolling24h > config.COST_ALERT_MAX_24H_SPEND) {
    void fireAlert(
      'max_24h_spend',
      `max_24h_spend breached ($${rolling24h.toFixed(2)} > $${config.COST_ALERT_MAX_24H_SPEND})`,
    );
  }
  if (oldestAge > config.COST_ALERT_MAX_POD_AGE_SECONDS) {
    void fireAlert(
      'max_pod_age',
      `max_pod_age breached (${Math.round(oldestAge / 60)}m > ${Math.round(config.COST_ALERT_MAX_POD_AGE_SECONDS / 60)}m)`,
    );
  }

  // Monthly cap circuit breaker
  const estimatedMonthly = rolling24h * 30;
  if (estimatedMonthly > config.COST_ALERT_MAX_MONTHLY_SPEND && costGateOpen) {
    costGateOpen = false;
    log.error(
      { estimatedMonthly, cap: config.COST_ALERT_MAX_MONTHLY_SPEND },
      'Monthly spend cap tripped — new provisions will be rejected',
    );
    void fireAlert(
      'monthly_cap',
      `MONTHLY CAP TRIPPED: projected $${estimatedMonthly.toFixed(0)}/mo > $${config.COST_ALERT_MAX_MONTHLY_SPEND} cap. New provisions blocked.`,
    );
  } else if (estimatedMonthly <= config.COST_ALERT_MAX_MONTHLY_SPEND * 0.8 && !costGateOpen) {
    // Re-open gate if spend drops to 80% of cap (hysteresis)
    costGateOpen = true;
    log.info('Monthly spend dropped below 80% of cap — provisions re-enabled');
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

function computeRolling24h(): number {
  if (ringBuffer.length < 2) return 0;
  let total = 0;
  for (let i = 1; i < ringBuffer.length; i++) {
    const prev = ringBuffer[i - 1]!;
    const curr = ringBuffer[i]!;
    const dtHours =
      (new Date(curr.timestamp).getTime() - new Date(prev.timestamp).getTime()) / 3_600_000;
    total += ((prev.burnPerHr + curr.burnPerHr) / 2) * dtHours;
  }
  return total;
}

function checkDailyRollup(now: Date): void {
  const day = now.getUTCDate();
  if (day === currentDayUtc) return;

  // Day rolled over — emit daily summary for the prior day
  const yesterday = new Date(now);
  yesterday.setUTCDate(yesterday.getUTCDate() - 1);
  const dayUtc = yesterday.toISOString().slice(0, 10);
  const dailyTotal = computeRolling24h(); // approximation using current buffer

  log.info(
    {
      event: 'kiki.cost.daily',
      dayUtc,
      totalDollars: Math.round(dailyTotal * 100) / 100,
      peakBurnPerHr: Math.round(dayPeakBurnPerHr * 100) / 100,
      peakActivePodCount: dayPeakActivePods,
      sampleCount: daySampleCount,
    },
    'Daily cost rollup',
  );

  // Reset for new day
  currentDayUtc = day;
  dayPeakBurnPerHr = 0;
  dayPeakActivePods = 0;
  daySampleCount = 0;
}

function lastAlertTimestamp(): string | null {
  let max = 0;
  for (const ts of lastAlertAt.values()) {
    if (ts > max) max = ts;
  }
  return max > 0 ? new Date(max).toISOString() : null;
}

async function fireAlert(key: string, message: string): Promise<void> {
  const now = Date.now();
  const lastFired = lastAlertAt.get(key) ?? 0;
  const cooldownMs = config.COST_ALERT_COOLDOWN_SECONDS * 1000;

  if (now - lastFired < cooldownMs) return; // still in cooldown
  lastAlertAt.set(key, now);

  const snap = latestSnapshot;
  const text = `[kiki] cost alert: ${message}. 24h spend: $${snap?.rolling24hTotal.toFixed(2) ?? '?'}. Active pods: ${snap?.activePodCount ?? '?'}. Oldest: ${Math.round((snap?.oldestPodAgeSeconds ?? 0) / 60)}m.`;

  log.warn({ event: 'kiki.cost.alert', key, message }, text);

  const webhookUrl = config.COST_ALERT_WEBHOOK_URL;
  if (!webhookUrl) return;

  // Discord webhook format (content + embeds). Color is decimal:
  // 0xFF0000 (red) = 16711680, 0xFFA500 (orange) = 16750848.
  const color = key === 'monthly_cap' ? 16711680 : 16750848;
  try {
    await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        content: text,
        embeds: [
          {
            color,
            fields: [
              { name: 'activePods', value: String(snap?.activePodCount ?? 0), inline: true },
              { name: 'burnPerHr', value: `$${snap?.currentBurnPerHr.toFixed(2) ?? '?'}`, inline: true },
              { name: 'rolling24hTotal', value: `$${snap?.rolling24hTotal.toFixed(2) ?? '?'}`, inline: true },
              { name: 'oldestPodAge', value: `${Math.round((snap?.oldestPodAgeSeconds ?? 0) / 60)}m`, inline: true },
            ],
          },
        ],
      }),
      signal: AbortSignal.timeout(5000),
    });
  } catch (err) {
    log.warn({ err: (err as Error).message, key }, 'Cost alert webhook failed');
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Ops auth helper (shared with ops routes)
// ────────────────────────────────────────────────────────────────────────────

async function sendHourlyDigest(): Promise<void> {
  const webhookUrl = config.COST_ALERT_WEBHOOK_URL;
  if (!webhookUrl) return;

  const snap = latestSnapshot;
  if (!snap) return;

  const content = `📊 **Hourly cost digest** — ${new Date().toUTCString()}`;
  try {
    await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        content,
        embeds: [
          {
            color: 3447003, // blue
            fields: [
              { name: 'Active pods', value: String(snap.activePodCount), inline: true },
              { name: 'Burn rate', value: `$${snap.currentBurnPerHr.toFixed(2)}/hr`, inline: true },
              { name: 'Rolling 24h', value: `$${snap.rolling24hTotal.toFixed(2)}`, inline: true },
              { name: 'Oldest pod', value: `${Math.round(snap.oldestPodAgeSeconds / 60)}m`, inline: true },
            ],
          },
        ],
      }),
      signal: AbortSignal.timeout(5000),
    });
  } catch (err) {
    log.warn({ err: (err as Error).message }, 'Hourly digest webhook failed');
  }
}

/** Constant-time comparison of the X-Ops-Key header against OPS_API_KEY. */
export function isValidOpsKey(provided: string | undefined): boolean {
  const expected = config.OPS_API_KEY;
  if (!expected || !provided) return false;
  if (provided.length !== expected.length) return false;
  return timingSafeEqual(Buffer.from(provided), Buffer.from(expected));
}
