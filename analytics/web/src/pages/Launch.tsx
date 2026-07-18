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


      <div className="section-title">H100 provisioning — all stats out of total sessions (7d)</div>
      <div className="stat-row">
        {(() => {
          const rows = data.providers ?? [];
          const lam = rows.find((r) => r.provider === 'lambda');
          const fal = rows.find((r) => r.provider === 'fal');
          const framesOf = (r?: { frames: number | string }) => Number(r?.frames ?? 0);
          const totalSessions = rows.reduce((a, r) => a + r.sessions, 0);
          const totalFrames = rows.reduce((a, r) => a + framesOf(r), 0);
          const gotH100 = lam ? lam.sessions - lam.bounced : 0;
          const h100Drops = lam?.sessions_with_disconnect ?? 0;
          return (
            <>
              <div className="stat">
                <div className="label">Sessions (7d)</div>
                <div className="value">{totalSessions}</div>
                <div className="sub">
                  {lam?.sessions ?? 0} tried H100 · {fal?.sessions ?? 0} fal
                </div>
              </div>
              <div className="stat">
                <div className="label">Got an H100</div>
                <div className="value">{pct(gotH100, totalSessions)}</div>
                <div className="sub">
                  {gotH100} of {totalSessions} sessions{lam && lam.bounced > 0 ? ` · ${lam.bounced} bounced` : ''}
                </div>
              </div>
              <div className="stat">
                <div className="label">Wait for H100</div>
                <div className="value">{lam?.wait_p50_ms != null ? fmtMsShort(lam.wait_p50_ms) : '—'}</div>
                <div className="sub">p50 · p90 {lam?.wait_p90_ms != null ? fmtMsShort(lam.wait_p90_ms) : '—'} · sessions that got one</div>
              </div>
              <div className="stat">
                <div className="label">Frames on H100</div>
                <div className="value">{totalFrames > 0 ? pct(framesOf(lam), totalFrames) : '—'}</div>
                <div className="sub">
                  {framesOf(lam).toLocaleString()} of {totalFrames.toLocaleString()} frames
                </div>
              </div>
              <div className="stat">
                <div className="label">Lost H100 mid-session</div>
                <div className="value">{gotH100 > 0 ? pct(h100Drops, gotH100) : '—'}</div>
                <div className="sub">
                  {h100Drops} of {gotH100} H100 sessions · {lam?.reconnects ?? 0} reconnected
                </div>
              </div>
            </>
          );
        })()}
      </div>

      {data.h100_waterfall && data.h100_waterfall.sessions > 0 && (
        <>
          <div className="section-title">H100 waterfall — how far sessions got (7d)</div>
          <div className="card">
            {(() => {
              const w = data.h100_waterfall;
              if (!w) return null;
              const p = data.h100_pool;
              const untracked = w.sessions - w.tracked;
              interface StageTiming {
                min: number | null | undefined;
                med: number | null | undefined;
                max: number | null | undefined;
                side: 'pool' | 'session';
                /** Sample size behind the duration — for pool-side stages this
                 * is instance events (launches/boots), NOT sessions, so it can
                 * be nonzero while the Sessions column reads 0. */
                n?: number | null;
              }
              const steps: { label: string; n: number; lost: string; t: StageTiming | null }[] = [
                { label: 'Sessions (any provider)', n: w.sessions, lost: '', t: null },
                {
                  label: 'Requested an H100',
                  n: w.requested,
                  lost: w.sessions - untracked - w.requested > 0 ? `${w.sessions - untracked - w.requested} explicitly chose fal` : '',
                  t: null,
                },
                {
                  label: 'Found an H100 (instance existed)',
                  n: w.found,
                  lost: w.requested - w.found > 0 ? `${w.requested - w.found} pool cold / still searching for capacity` : '',
                  t: { min: p?.search_min_ms, med: p?.search_p50_ms, max: p?.search_max_ms, side: 'pool', n: p?.capacity_granted },
                },
                {
                  label: 'H100 warmed (ready)',
                  n: w.warmed,
                  lost: w.found - w.warmed > 0 ? `${w.found - w.warmed} instance still warming` : '',
                  t: { min: p?.boot_min_ms, med: p?.boot_p50_ms, max: p?.boot_max_ms, side: 'pool', n: p?.became_ready },
                },
                {
                  label: 'Connected to the H100',
                  n: w.connected,
                  lost: w.warmed - w.connected > 0 ? `${w.warmed - w.connected} connect failed` : '',
                  t: { min: w.connect_min_ms, med: w.connect_med_ms, max: w.connect_max_ms, side: 'session' },
                },
                {
                  label: '≥1 frame from the H100',
                  n: w.h100_frames,
                  lost: w.connected - w.h100_frames > 0 ? `${w.connected - w.h100_frames} connected but no frames` : '',
                  t: { min: w.ff_min_ms, med: w.ff_med_ms, max: w.ff_max_ms, side: 'session' },
                },
                {
                  label: 'No H100 drop to session end',
                  n: w.held,
                  lost:
                    w.downgraded + w.dropped > 0
                      ? `lost the H100: ${w.downgraded} downgraded to fal · ${w.dropped} dropped (reconnected in-session)`
                      : '',
                  t: null,
                },
              ];
              // Shared grid template so the header and every row align into a
              // real table: stage | bar | sessions | min | median | max | side.
              const GRID = '215px 1fr 90px 64px 64px 64px 88px';
              const cell = (v: number | null | undefined, bold = false): React.ReactNode =>
                v == null ? <span className="muted">—</span> : bold ? <strong>{fmtMsShort(v)}</strong> : fmtMsShort(v);
              const headerCell: React.CSSProperties = {
                fontSize: 11,
                textTransform: 'uppercase',
                letterSpacing: '.04em',
                color: 'var(--muted)',
              };
              const numCell: React.CSSProperties = { fontSize: 12, textAlign: 'right', whiteSpace: 'nowrap' };
              return (
                <>
                  <div
                    style={{
                      display: 'grid',
                      gridTemplateColumns: GRID,
                      gap: 12,
                      alignItems: 'center',
                      padding: '2px 0 8px',
                      borderBottom: '1px solid var(--border)',
                    }}
                  >
                    <span style={headerCell}>Stage</span>
                    <span style={headerCell}>Completion</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Sessions</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Min</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Median</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Max</span>
                    <span
                      style={{ ...headerCell, textAlign: 'right' }}
                      title="Whose clock: pool = fleet-side (users aren't waiting — fal serves meanwhile); session = experienced by wired sessions."
                    >
                      Timed by
                    </span>
                  </div>
                  {steps.map((s) => (
                    <div key={s.label} style={{ borderBottom: '1px solid var(--border)', padding: '7px 0' }}>
                      <div style={{ display: 'grid', gridTemplateColumns: GRID, gap: 12, alignItems: 'center' }}>
                        <span className="muted" style={{ fontSize: 13 }}>{s.label}</span>
                        <div style={{ background: 'var(--panel-2)', borderRadius: 6, height: 20 }}>
                          <div
                            style={{
                              width: `${Math.max(s.n > 0 ? 2 : 0, (s.n / w.sessions) * 100)}%`,
                              background: '#5b93ea',
                              height: '100%',
                              borderRadius: 6,
                            }}
                          />
                        </div>
                        <span style={{ ...numCell, fontSize: 13 }}>
                          {s.n} <span className="muted">({pct(s.n, w.sessions)})</span>
                        </span>
                        <span style={numCell}>{s.t ? cell(s.t.min ?? s.t.med) : <span className="muted">—</span>}</span>
                        <span style={numCell}>{s.t ? cell(s.t.med, true) : <span className="muted">—</span>}</span>
                        <span style={numCell}>{s.t ? cell(s.t.max ?? s.t.med) : <span className="muted">—</span>}</span>
                        <span style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                          {s.t && s.t.med != null ? (
                            <span
                              className="pill"
                              style={{ fontSize: 10 }}
                              title={
                                s.t.side === 'pool'
                                  ? `Duration measured over ${s.t.n ?? '?'} pool event(s) (instance launches/boots) — a fleet-side clock, independent of the session count on this row.`
                                  : 'Duration measured over the sessions counted on this row.'
                              }
                            >
                              {s.t.side}
                              {s.t.side === 'pool' && s.t.n != null ? ` · n=${s.t.n}` : ''}
                            </span>
                          ) : (
                            <span className="muted">—</span>
                          )}
                        </span>
                      </div>
                      {s.lost && (
                        <div style={{ fontSize: 12, marginLeft: 227, marginTop: 3, color: '#f0b429' }}>
                          {s.lost}
                        </div>
                      )}
                    </div>
                  ))}
                  <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
                    {untracked > 0 && (
                      <>
                        {untracked} session{untracked === 1 ? '' : 's'} predate stage tracking (counted in
                        the first bar only).{' '}
                      </>
                    )}
                    Pool this week:{' '}
                    {p && p.launch_requests + p.capacity_granted + p.became_ready > 0
                      ? `${p.launch_requests} capacity searches → ${p.capacity_granted} granted (p50 ${p.search_p50_ms != null ? fmtMsShort(p.search_p50_ms) : '—'}) → ${p.became_ready} warmed to ready (p50 ${p.boot_p50_ms != null ? fmtMsShort(p.boot_p50_ms) : '—'})${p.launch_failed ? ` · ${p.launch_failed} launches failed` : ''}${p.died ? ` · ${p.died} instances died` : ''}`
                      : 'no pool launches recorded yet'}
                  </div>
                  <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
                    Durations: how long that stage took to complete. Rows tagged <span className="pill" style={{ fontSize: 10 }}>pool</span> are
                    timed over instance events (n shown) — a fleet-side clock that can be nonzero even when
                    no session has passed the stage yet. “—” = the stage is an instant (nothing to time).
                  </div>
                </>
              );
            })()}
          </div>
        </>
      )}

      {data.drawing_funnel && data.drawing_funnel.opened > 0 && (
        <>
          <div className="section-title">Drawing waterfall — engagement per canvas session (7d)</div>
          <div className="card">
            {(() => {
              const f = data.drawing_funnel;
              if (!f) return null;
              const num = (k: string): number => (f[k] as number | null) ?? 0;
              const opened = f.opened;
              const GRID = '215px 1fr 90px 64px 64px 64px 88px';
              const cellV = (v: number | null | undefined, bold = false): React.ReactNode =>
                v == null ? <span className="muted">—</span> : bold ? <strong>{fmtMsShort(v)}</strong> : fmtMsShort(v);
              const noClose = opened - num('closed');
              const rows: { label: string; n: number; lost: string; tk: string | null }[] = [
                { label: 'Canvas opened', n: opened, lost: '', tk: null },
                {
                  label: 'First stroke made',
                  n: num('stroked'),
                  lost: [
                    num('closed') - num('stroked') > 0 ? `${num('closed') - num('stroked')} opened but never drew` : '',
                    noClose > 0 ? `${noClose} no close record yet (still open / app killed)` : '',
                  ]
                    .filter(Boolean)
                    .join(' · '),
                  tk: 'stroked',
                },
                {
                  label: 'First generated image',
                  n: num('gen1'),
                  lost: num('stroked') - num('gen1') > 0 ? `${num('stroked') - num('gen1')} drew but got no image` : '',
                  tk: 'gen1',
                },
                { label: '>10 generated images', n: num('gen10'), lost: '', tk: 'gen10' },
                { label: '>50 generated images', n: num('gen50'), lost: '', tk: 'gen50' },
                { label: '>100 generated images', n: num('gen100'), lost: '', tk: 'gen100' },
              ];
              const headerCell: React.CSSProperties = {
                fontSize: 11,
                textTransform: 'uppercase',
                letterSpacing: '.04em',
                color: 'var(--muted)',
              };
              const numCell: React.CSSProperties = { fontSize: 12, textAlign: 'right', whiteSpace: 'nowrap' };
              return (
                <>
                  <div
                    style={{
                      display: 'grid',
                      gridTemplateColumns: GRID,
                      gap: 12,
                      alignItems: 'center',
                      padding: '2px 0 8px',
                      borderBottom: '1px solid var(--border)',
                    }}
                  >
                    <span style={headerCell}>Stage</span>
                    <span style={headerCell}>Completion</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Sessions</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Min</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Median</span>
                    <span style={{ ...headerCell, textAlign: 'right' }}>Max</span>
                    <span style={{ ...headerCell, textAlign: 'right' }} title="Session length (open→close) among sessions that reached this stage.">
                      Timed by
                    </span>
                  </div>
                  {rows.map((s) => {
                    const med = s.tk ? (f[`${s.tk}_med_ms`] as number | null) : null;
                    return (
                      <div key={s.label} style={{ borderBottom: '1px solid var(--border)', padding: '7px 0' }}>
                        <div style={{ display: 'grid', gridTemplateColumns: GRID, gap: 12, alignItems: 'center' }}>
                          <span className="muted" style={{ fontSize: 13 }}>{s.label}</span>
                          <div style={{ background: 'var(--panel-2)', borderRadius: 6, height: 20 }}>
                            <div
                              style={{
                                width: `${Math.max(s.n > 0 ? 2 : 0, (s.n / opened) * 100)}%`,
                                background: '#5b93ea',
                                height: '100%',
                                borderRadius: 6,
                              }}
                            />
                          </div>
                          <span style={{ ...numCell, fontSize: 13 }}>
                            {s.n} <span className="muted">({pct(s.n, opened)})</span>
                          </span>
                          <span style={numCell}>{s.tk ? cellV(f[`${s.tk}_min_ms`] as number | null) : <span className="muted">—</span>}</span>
                          <span style={numCell}>{s.tk ? cellV(med, true) : <span className="muted">—</span>}</span>
                          <span style={numCell}>{s.tk ? cellV(f[`${s.tk}_max_ms`] as number | null) : <span className="muted">—</span>}</span>
                          <span style={{ textAlign: 'right' }}>
                            {s.tk && med != null ? (
                              <span className="pill" style={{ fontSize: 10 }} title="Total canvas-session length among sessions that reached this stage.">
                                session
                              </span>
                            ) : (
                              <span className="muted">—</span>
                            )}
                          </span>
                        </div>
                        {s.lost && (
                          <div style={{ fontSize: 12, marginLeft: 227, marginTop: 3, color: '#f0b429' }}>{s.lost}</div>
                        )}
                      </div>
                    );
                  })}
                  <div className="muted" style={{ fontSize: 12, marginTop: 10 }}>
                    Each canvas open is its own funnel (reopening or switching canvases starts a new one).
                    Durations are the total canvas-session length (open→close) among sessions that reached
                    the stage. “First stroke” uses generated&gt;0 as a proxy for sessions recorded before
                    the strokes_added field shipped (next iOS build).
                  </div>
                </>
              );
            })()}
          </div>
        </>
      )}

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
