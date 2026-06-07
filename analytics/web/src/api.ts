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
