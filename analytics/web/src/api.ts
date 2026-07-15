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
  sessions: SessionRow[];
  events: EventRow[];
  drawings: DrawingRow[];
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

export const putWarmer = (config: WarmerConfig) =>
  api<{ ok: boolean; config: WarmerConfig }>('/admin/api/ops/warmer', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(config),
  });
