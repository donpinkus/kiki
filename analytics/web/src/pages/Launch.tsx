import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { getLaunch, type LaunchData, type LaunchDaily } from '../api';
import { DailyBars } from '../ActivityBars';

const fmtMsShort = (ms: number) => (ms < 10_000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.round(ms / 1000)}s`);
const fmtAgo = (iso: string) => {
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 48 * 3600) return `${Math.round(s / 3600)}h ago`;
  return new Date(iso).toLocaleDateString();
};
const pct = (n: number, of: number) => (of > 0 ? `${Math.round((n / of) * 100)}%` : '—');

function seriesMap(daily: LaunchDaily[], key: keyof LaunchDaily): Record<string, number | null> {
  const m: Record<string, number | null> = {};
  for (const d of daily) m[d.day] = (d[key] as number | null | undefined) ?? null;
  return m;
}

/** Aggregate launch dashboard: daily trends, activation funnel, weekly
 * retention cohorts, and the error-triage lists. All read-only views over
 * events/sessions/users already collected. */
export function Launch() {
  const [data, setData] = useState<LaunchData | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Persisted so "real users only" can be set once and survive reloads.
  const [excludeTest, setExcludeTest] = useState(
    () => localStorage.getItem('launch.excludeTest') === '1',
  );

  useEffect(() => {
    localStorage.setItem('launch.excludeTest', excludeTest ? '1' : '0');
    setData(null);
    getLaunch(excludeTest).then(setData).catch((e) => setError(String(e)));
    const t = setInterval(() => getLaunch(excludeTest).then(setData).catch(() => {}), 60_000);
    return () => clearInterval(t);
  }, [excludeTest]);

  const today = new Date().toLocaleDateString('en-CA');
  const stats = useMemo(() => {
    if (!data) return null;
    const t = data.daily.find((d) => d.day === today);
    const last7 = data.daily.filter((d) => new Date(d.day) > new Date(Date.now() - 7 * 86_400_000));
    return {
      dauToday: t?.dau ?? 0,
      newUsers7d: last7.reduce((s, d) => s + (d.new_users ?? 0), 0),
      drawings7d: last7.reduce((s, d) => s + (d.drawings ?? 0), 0),
      errors24h: t?.errors ?? 0,
      dead7d: last7.reduce((s, d) => s + (d.dead_streams ?? 0), 0),
    };
  }, [data, today]);

  if (error) return <div className="container error">{error}</div>;
  if (!data || !stats) return <div className="container muted">Loading…</div>;

  const f = data.funnel;
  const funnelSteps = [
    { label: 'Signed up', n: f.signed_up },
    { label: 'Opened a drawing', n: f.opened_drawing },
    { label: 'Saw a generated image', n: f.saw_image },
    { label: 'Came back a later day', n: f.returned },
  ];

  return (
    <div className="container">
      <div className="section-title" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <span>Launch — at a glance</span>
        <label
          title="Filters users.is_test_account out of every number on this page"
          style={{ display: 'flex', gap: 6, alignItems: 'center', cursor: 'pointer', textTransform: 'none', letterSpacing: 0 }}
        >
          <input
            type="checkbox"
            checked={excludeTest}
            onChange={(e) => setExcludeTest(e.target.checked)}
          />
          Exclude test accounts
        </label>
      </div>
      <div className="stat-row">
        <div className="stat">
          <div className="label">Active today</div>
          <div className="value">{stats.dauToday}</div>
          <div className="sub">users with any activity</div>
        </div>
        <div className="stat">
          <div className="label">New users (7d)</div>
          <div className="value">{stats.newUsers7d}</div>
          <div className="sub">{f.signed_up} all-time</div>
        </div>
        <div className="stat">
          <div className="label">Drawings (7d)</div>
          <div className="value">{stats.drawings7d}</div>
          <div className="sub">created</div>
        </div>
        <div className="stat">
          <div className="label">Time to first image</div>
          <div className="value">{data.summary?.ttfi_p50_7d != null ? fmtMsShort(data.summary.ttfi_p50_7d) : '—'}</div>
          <div className="sub">p50 · p90 {data.summary?.ttfi_p90_7d != null ? fmtMsShort(data.summary.ttfi_p90_7d) : '—'} (7d)</div>
        </div>
        <div className="stat">
          <div className="label">Errors today</div>
          <div className="value">{stats.errors24h}</div>
          <div className="sub">{stats.dead7d} dead streams (7d)</div>
        </div>
      </div>


      <div className="section-title">Image providers — H100 visibility (7d)</div>
      <div className="stat-row">
        {(() => {
          const rows = data.providers ?? [];
          const lam = rows.find((r) => r.provider === 'lambda');
          const fal = rows.find((r) => r.provider === 'fal');
          const framesOf = (r?: { frames: number | string }) => Number(r?.frames ?? 0);
          const totalFrames = rows.reduce((a, r) => a + framesOf(r), 0);
          const lamAttempts = lam ? lam.sessions : 0;
          const lamOk = lam ? lam.sessions - lam.bounced : 0;
          return (
            <>
              <div className="stat">
                <div className="label">H100 sessions (7d)</div>
                <div className="value">{lamOk}/{lamAttempts || '0'}</div>
                <div className="sub">{lam && lamAttempts > 0 ? `${Math.round((lamOk / lamAttempts) * 100)}% got the H100 · ${lam.bounced} bounced` : 'no lambda sessions'}</div>
              </div>
              <div className="stat">
                <div className="label">Time to H100</div>
                <div className="value">{lam?.wait_p50_ms != null ? fmtMsShort(lam.wait_p50_ms) : '—'}</div>
                <div className="sub">p50 · p90 {lam?.wait_p90_ms != null ? fmtMsShort(lam.wait_p90_ms) : '—'}</div>
              </div>
              <div className="stat">
                <div className="label">H100 disconnects</div>
                <div className="value">{lam?.disconnects ?? 0}</div>
                <div className="sub">{lam?.reconnects ?? 0} recovered in-session</div>
              </div>
              <div className="stat">
                <div className="label">Frames by provider</div>
                <div className="value">{totalFrames > 0 ? `${Math.round((framesOf(lam) / totalFrames) * 100)}%` : '—'}</div>
                <div className="sub">lambda · fal {totalFrames > 0 ? `${Math.round((framesOf(fal) / totalFrames) * 100)}%` : '—'} · {totalFrames.toLocaleString()} total</div>
              </div>
              <div className="stat">
                <div className="label">fal sessions (7d)</div>
                <div className="value">{fal?.sessions ?? 0}</div>
                <div className="sub">{fal?.disconnects ?? 0} disconnects</div>
              </div>
            </>
          );
        })()}
      </div>

      <div className="section-title">Trends (30 days)</div>
      <div className="launch-grid">
        <DailyBars title="New users" byDay={seriesMap(data.daily, 'new_users')} />
        <DailyBars title="Daily active users" byDay={seriesMap(data.daily, 'dau')} />
        <DailyBars title="Drawings created" byDay={seriesMap(data.daily, 'drawings')} />
        <DailyBars title="Generated frames" byDay={seriesMap(data.daily, 'frames')} />
        <DailyBars title="Time to first image — p50" byDay={seriesMap(data.daily, 'ttfi_p50')} fmtValue={fmtMsShort} />
        <DailyBars title="Time to first image — p90" byDay={seriesMap(data.daily, 'ttfi_p90')} fmtValue={fmtMsShort} />
        <DailyBars title="Error events" byDay={seriesMap(data.daily, 'errors')} color="#f0b429" />
        <DailyBars title="Dead streams (0 frames)" byDay={seriesMap(data.daily, 'dead_streams')} color="#ff7b72" />
      </div>

      <div className="section-title">Activation funnel (all-time)</div>
      <div className="card">
        {funnelSteps.map((s, i) => (
          <div key={s.label} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '6px 0' }}>
            <span className="muted" style={{ width: 190, fontSize: 13 }}>{s.label}</span>
            <div style={{ flex: 1, background: 'var(--panel-2)', borderRadius: 6, height: 22, position: 'relative' }}>
              <div
                style={{
                  width: pct(s.n, f.signed_up) === '—' ? 0 : `${Math.max(2, (s.n / f.signed_up) * 100)}%`,
                  background: '#5b93ea',
                  height: '100%',
                  borderRadius: 6,
                }}
              />
            </div>
            <span style={{ width: 110, fontSize: 13 }}>
              {s.n} <span className="muted">({i === 0 ? '100%' : pct(s.n, f.signed_up)})</span>
            </span>
          </div>
        ))}
        <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
          Steps: account exists → any drawing.opened → any stream.first_frame → any activity on a
          day after the Pacific signup day.
        </div>
      </div>

      <div className="section-title">Retention by signup week</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Cohort (week of)</th>
              <th>Signups</th>
              <th>D1</th>
              <th>W1 (any of days 1–7)</th>
            </tr>
          </thead>
          <tbody>
            {data.cohorts.map((c) => (
              <tr key={c.week}>
                <td>{new Date(`${c.week}T12:00:00`).toLocaleDateString([], { month: 'short', day: 'numeric' })}</td>
                <td>{c.signups}</td>
                <td>{c.d1} <span className="muted">({pct(c.d1, c.signups)})</span></td>
                <td>{c.w1} <span className="muted">({pct(c.w1, c.signups)})</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="section-title">Error triage — affected users (7d)</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>User</th>
              <th>Error events</th>
              <th>Last</th>
            </tr>
          </thead>
          <tbody>
            {data.errorUsers.map((u) => (
              <tr key={u.user_id}>
                <td>
                  <Link to={`/users/${u.user_id}`}>{u.email ?? <span className="mono">{u.user_id.slice(0, 8)}</span>}</Link>
                </td>
                <td>{u.errors}</td>
                <td className="muted">{fmtAgo(u.last_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {data.errorUsers.length === 0 && (
          <div className="muted" style={{ padding: 16 }}>No error events in the last 7 days 🎉</div>
        )}
      </div>

      <div className="section-title">Most recent error events</div>
      <div className="events card">
        {data.recentErrors.map((e, i) => (
          <div
            key={`${e.occurred_at}-${i}`}
            className="event-row"
            style={{ gridTemplateColumns: '90px 200px 190px 1fr' }}
          >
            <span className="ts">{fmtAgo(e.occurred_at)}</span>
            <span className="name">{e.name}</span>
            <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              <Link to={`/users/${e.user_id}`}>{e.email ?? e.user_id.slice(0, 8)}</Link>
            </span>
            <span className="props mono" title={JSON.stringify(e.properties)}>
              {JSON.stringify(e.properties)}
            </span>
          </div>
        ))}
        {data.recentErrors.length === 0 && <div className="muted">None recorded.</div>}
      </div>
    </div>
  );
}
