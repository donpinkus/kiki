// Thin fetch wrapper. All requests are same-origin and rely on the admin
// session cookie (httpOnly), so we just need credentials: 'include'.

export interface UserSummary {
  user_id: string;
  email: string | null;
  is_test_account: boolean;
  subscription_status: string;
  created_at: string;
  last_seen: string | null;
  event_count: number;
  session_count: number;
  drawing_count: number;
  fal_spend_usd_month: number;
  /** In-app minutes per Pacific day, oldest→today, exactly 14 entries. */
  activity14d: number[];
}

export interface SessionRow {
  id: number;
  source: 'app' | 'drawing';
  started_at: string;
  ended_at: string | null;
  duration_ms: number | null;
  drawing_id: string | null;
}

export interface EventRow {
  id: number;
  name: string;
  properties: Record<string, unknown>;
  occurred_at: string;
  source: string;
  stream_id: string | null;
  drawing_id: string | null;
}

export interface DrawingRow {
  drawing_id: string;
  prompt: string | null;
  style_id: string | null;
  created_at: string | null;
  updated_at: string | null;
  thumbnail_url: string | null;
  generated_url: string | null;
  video_key: string | null;
}

export interface MonthlyUsageRow {
  month: string;
  fal_spend_usd: number;
}

export interface UserDetail {
  user: {
    user_id: string;
    email: string | null;
    apple_sub: string | null;
    is_test_account: boolean;
    subscription_status: string;
    subscription_expires_at: string | null;
    created_at: string;
    updated_at: string;
  };
  usage: MonthlyUsageRow[];
  /** In-app minutes per Pacific day since first session (zero days omitted). */
  daily_activity: { day: string; minutes: number }[];
  sessions: SessionRow[];
  events: EventRow[];
  drawings: DrawingRow[];
  provider_stats: ProviderStatsRow[];
}

class AuthError extends Error {}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, { credentials: 'include', ...init });
  if (res.status === 401) throw new AuthError('unauthorized');
  if (!res.ok) throw new Error(`${path} → ${res.status}`);
  return res.json() as Promise<T>;
}

export const isAuthError = (e: unknown): e is AuthError => e instanceof AuthError;

export const checkAuth = () => api<{ ok: boolean }>('/admin/api/me');

export const login = (password: string) =>
  api<{ ok: boolean }>('/admin/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password }),
  });

export const logout = () => api<{ ok: boolean }>('/admin/logout', { method: 'POST' });

export const listUsers = (q: string) =>
  api<{ users: UserSummary[] }>(`/admin/api/users?q=${encodeURIComponent(q)}`);

export const getUser = (id: string) => api<UserDetail>(`/admin/api/users/${encodeURIComponent(id)}`);

// ─── Ops: fal keep-warm dial ────────────────────────────────────────────────

export interface WarmerConfig {
  enabled: boolean;
  intervalMs: number;
  offStartHour: number;
  offEndHour: number;
}

export interface WarmerPing {
  ts: string;
  found_warm: boolean | null;
  ms_to_first_frame: number | null;
  open_ms: number;
  error: string | null;
}

export interface SourceStats {
  source: 'user' | 'warmer';
  conns: number;
  answered: number;
  cold: number;
  wait_p50: number | null;
  wait_p90: number | null;
  wait_max: number | null;
}

export interface ConnectionRow {
  opened_at: string;
  source: 'user' | 'warmer';
  user_id: string | null;
  email: string | null;
  wait_ms: number | null;
  found_warm: boolean | null;
  frames_sent: number;
  frames_received: number;
  open_ms: number;
  close_reason: string | null;
}

export type SourceFilter = 'all' | 'user' | 'warmer';

export interface WarmerStatus {
  schemaReady: boolean;
  config: WarmerConfig | null;
  configUpdatedAt: string | null;
  pings: WarmerPing[];
  stats24h: {
    pings: number;
    cold_encounters: number;
    failures: number;
    billed_ms: number;
  } | null;
  sources24h: SourceStats[];
}

export const getWarmer = () => api<WarmerStatus>('/admin/api/ops/warmer');

// ─── Session replays (capture gallery) ──────────────────────────────────────

export interface CaptureStreamSummary {
  stream_id: string;
  user_id: string;
  email: string | null;
  started_at: string;
  ended_at: string;
  sketch_count: number;
  generated_count: number;
  poster_url: string | null;
  last_prompt: string | null;
}

export interface CapturePrompt {
  seq: number;
  captured_at: string;
  prompt: string;
}

export interface CaptureFrame {
  kind: 'sketch' | 'generated';
  seq: number;
  captured_at: string;
  url: string;
}

export interface CaptureDetail {
  stream_id: string;
  user_id: string | null;
  email: string | null;
  frames: CaptureFrame[];
  prompts: CapturePrompt[];
}

export const listCaptures = (userId?: string) =>
  api<{ captures: CaptureStreamSummary[] }>(
    `/admin/api/captures${userId ? `?user_id=${encodeURIComponent(userId)}` : ''}`,
  );

export const getCapture = (streamId: string) =>
  api<CaptureDetail>(`/admin/api/captures/${encodeURIComponent(streamId)}`);

export const getConnections = (source: SourceFilter) =>
  api<{ schemaReady: boolean; connections: ConnectionRow[] }>(
    `/admin/api/ops/connections${source === 'all' ? '' : `?source=${source}`}`,
  );

export interface VideoFlagStatus {
  schemaReady: boolean;
  seeded: boolean;
  config: { enabled: boolean };
  updatedAt: string | null;
}

export interface FleetImage {
  sessions: number; requested: number; wired: number; framed: number;
  downgraded: number; disconnected: number;
  wait_p50_ms: number | null; wait_p90_ms: number | null;
  first_frame_p50_ms: number | null;
  gen_p50_ms: number | null; gen_p90_ms: number | null;
  frames_delivered: number; sketches_sent: number;
  h100_frames_delivered: number; h100_sketches_sent: number;
}

export interface FleetVideo {
  video_sessions: number; sessions_triggered: number; sessions_delivered: number;
  videos_triggered: number; videos_delivered: number;
  videos_cancelled: number; videos_failed: number;
  delivered_events: number; manual_count: number;
  wait_p50_ms: number | null; wait_p90_ms: number | null;
  gen_p50_ms: number | null; gen_p90_ms: number | null;
}

export interface FleetPoolRow {
  pool: string;
  launch_requests: number; capacity_granted: number; became_ready: number;
  launch_failed: number; died: number; boot_stalled: number;
  idle_reaped: number; drained: number;
  search_p50_ms: number | null; search_max_ms: number | null;
  boot_p50_ms: number | null; boot_max_ms: number | null;
}

export interface FleetEventRow {
  ts: string; pool: string; event: string;
  instance_name: string | null; duration_ms: number | null; detail: string | null;
}

export interface FleetDailyRow {
  day: string; sessions: number; wired: number;
  wait_p50_ms: number | null; frames: number; sketches: number; videos: number;
}

export interface FleetData {
  image: FleetImage | null;
  video: FleetVideo | null;
  pools: FleetPoolRow[];
  recent_events: FleetEventRow[];
  daily: FleetDailyRow[];
}

export const getFleet = (excludeTest: boolean) =>
  api<FleetData>(`/admin/api/fleet${excludeTest ? '?excludeTest=1' : ''}`);

export const getVideoFlag = () => api<VideoFlagStatus>('/admin/api/ops/video');

export const putVideoFlag = (enabled: boolean) =>
  api<{ ok: boolean; config: { enabled: boolean } }>('/admin/api/ops/video', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ enabled }),
  });

export const putWarmer = (config: WarmerConfig) =>
  api<{ ok: boolean; config: WarmerConfig }>('/admin/api/ops/warmer', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(config),
  });

// ─── Brush-test battery runs (Tests tab) ────────────────────────────────────

export interface TestRunImage {
  scene: string;
  blob_key: string;
  description: string | null;
}

export interface TestRun {
  id: string;
  git_sha: string | null;
  note: string | null;
  created_at: string;
  images: TestRunImage[];
}

export const listTestRuns = () => api<{ runs: TestRun[] }>('/admin/api/test-runs');

// ─── Brush clone targets (Brushes tab) ──────────────────────────────────────

export interface BrushTargetImage {
  id: string;
  kind: 'reference' | 'settings' | 'attempt';
  label: string | null;
  note: string | null;
  blob_key: string;
  created_at: string;
}

export interface BrushTarget {
  id: string;
  name: string;
  note: string | null;
  status: 'todo' | 'in_progress' | 'matched';
  created_at: string;
  updated_at: string;
  images: BrushTargetImage[];
}

export const listBrushTargets = () => api<{ targets: BrushTarget[] }>('/admin/api/brush-targets');

export const createBrushTarget = (name: string, note: string) =>
  api<{ ok: boolean; id: string }>('/admin/api/brush-targets', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, note }),
  });

export const updateBrushTarget = (id: string, patch: { name?: string; note?: string; status?: string }) =>
  api<{ ok: boolean }>(`/admin/api/brush-targets/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch),
  });

export const deleteBrushTarget = (id: string) =>
  api<{ ok: boolean }>(`/admin/api/brush-targets/${id}`, { method: 'DELETE' });

export const uploadBrushTargetImages = (id: string, files: File[], kind: string) => {
  const form = new FormData();
  form.append('kind', kind);
  for (const f of files) form.append('image', f, f.name);
  return api<{ ok: boolean }>(`/admin/api/brush-targets/${id}/images`, { method: 'POST', body: form });
};

export const updateBrushTargetImage = (id: string, patch: { label?: string; note?: string; kind?: string }) =>
  api<{ ok: boolean }>(`/admin/api/brush-target-images/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(patch),
  });

export const deleteBrushTargetImage = (id: string) =>
  api<{ ok: boolean }>(`/admin/api/brush-target-images/${id}`, { method: 'DELETE' });

// ─── Launch analytics ────────────────────────────────────────────────────────

export interface LaunchDaily {
  day: string;
  dau?: number;
  new_users?: number;
  drawings?: number;
  streams?: number;
  frames?: number;
  dead_streams?: number;
  errors?: number;
  ttfi_p50?: number | null;
  ttfi_p90?: number | null;
}

export interface ProviderStatsRow {
  provider: string;
  sessions: number;
  bounced: number;
  wired?: number;
  wait_p50_ms: number | null;
  wait_p90_ms?: number | null;
  frames: number | string; // bigint may arrive as string
  disconnects: number;
  reconnects: number;
  sessions_with_disconnect?: number;
}

/** Session-side H100 waterfall (7d, ALL provider sessions). Cumulative:
 * sessions ⊇ requested ⊇ found ⊇ warmed ⊇ connected ⊇ h100_frames ⊇ held.
 * `downgraded` + `dropped` decompose the connected→held losses; `untracked`
 * (sessions − tracked) predate stage instrumentation. */
export interface H100Waterfall {
  sessions: number;
  tracked: number;
  requested: number;
  found: number;
  warmed: number;
  connected: number;
  h100_frames: number;
  held: number;
  downgraded: number;
  dropped: number;
  connect_min_ms: number | null;
  connect_med_ms: number | null;
  connect_max_ms: number | null;
  ff_min_ms: number | null;
  ff_med_ms: number | null;
  ff_max_ms: number | null;
}

/** Pool-side lifecycle counts + stage timings (7d). */
export interface H100Pool {
  launch_requests: number;
  capacity_granted: number;
  became_ready: number;
  launch_failed: number;
  died: number;
  search_p50_ms: number | null;
  search_min_ms: number | null;
  search_max_ms: number | null;
  boot_p50_ms: number | null;
  boot_min_ms: number | null;
  boot_max_ms: number | null;
}

export interface LaunchData {
  daily: LaunchDaily[];
  funnel: { signed_up: number; opened_drawing: number; saw_image: number; returned: number };
  cohorts: { week: string; signups: number; d1: number; w1: number }[];
  errorUsers: { user_id: string; email: string | null; errors: number; last_at: string }[];
  recentErrors: {
    occurred_at: string;
    user_id: string;
    email: string | null;
    name: string;
    properties: Record<string, unknown>;
  }[];
  summary: { ttfi_p50_7d: number | null; ttfi_p90_7d: number | null } | null;
  providers: ProviderStatsRow[];
  h100_waterfall: H100Waterfall | null;
  h100_pool: H100Pool | null;
  video_pool: VideoPool | null;
  video_generation: VideoGeneration | null;
  drawing_funnel: DrawingFunnel | null;
}

/** Video pool lifecycle counts (7d, lambda_pool_events pool='video'). */
export interface VideoPool {
  launch_requests: number;
  capacity_granted: number;
  became_ready: number;
  launch_failed: number;
  died: number;
  boot_stalled: number;
  drained: number;
  search_p50_ms: number | null;
  boot_p50_ms: number | null;
}

/** Video generation funnel (7d, stream.provider_session video_* counters). */
export interface VideoGeneration {
  video_sessions: number;
  sessions_triggered: number;
  sessions_delivered: number;
  videos_triggered: number;
  videos_delivered: number;
  videos_cancelled: number;
  videos_failed: number;
}

/** Drawing-experience waterfall: `opened` from drawing.opened; every other
 * key from drawing.closed aggregates — stage counts (closed, stroked, gen1,
 * gen10, gen50, gen100) plus `<stage>_min_ms` / `<stage>_med_ms` /
 * `<stage>_max_ms` session-duration stats. */
export type DrawingFunnel = { opened: number } & Record<string, number | null>;

export const getLaunch = (excludeTest: boolean) =>
  api<LaunchData>(`/admin/api/launch${excludeTest ? '?excludeTest=1' : ''}`);
