import { useEffect, useState } from 'react';
import {
  getConnections,
  getWarmer,
  putWarmer,
  type ConnectionRow,
  type SourceFilter,
  type WarmerConfig,
  type WarmerStatus,
} from '../api';

const FAL_USD_PER_SEC = 0.00194;

const fmtTime = (iso: string) =>
  new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', second: '2-digit' });
const fmtAgo = (iso: string) => {
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 48 * 3600) return `${Math.round(s / 3600)}h ago`;
  return new Date(iso).toLocaleString();
};
const fmtMs = (ms: number | null) =>
  ms === null ? '—' : ms < 10_000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.round(ms / 1000)}s`;

const pacificHour = () =>
  Number(
    new Intl.DateTimeFormat('en-US', {
      timeZone: 'America/Los_Angeles',
      hour: 'numeric',
      hour12: false,
    }).format(new Date()),
  ) % 24;

const inOffWindow = (hour: number, start: number, end: number) => {
  if (start === end) return false;
  return start < end ? hour >= start && hour < end : hour >= start || hour < end;
};

function warmerStateNow(cfg: WarmerConfig | null): { label: string; cls: string } {
  if (!cfg) return { label: 'not configured', cls: 'fail' };
  if (!cfg.enabled) return { label: 'disabled', cls: 'fail' };
  if (inOffWindow(pacificHour(), cfg.offStartHour, cfg.offEndHour))
    return { label: `sleeping (off ${cfg.offStartHour}–${cfg.offEndHour} Pacific)`, cls: 'cold' };
  return { label: 'active', cls: 'warm' };
}

export function Ops() {
  const [status, setStatus] = useState<WarmerStatus | null>(null);
  const [videoFlag, setVideoFlag] = useState<{ enabled: boolean; updatedAt: string | null } | null>(null);
  const [videoSaving, setVideoSaving] = useState(false);
  const [connections, setConnections] = useState<ConnectionRow[]>([]);
  const [sourceFilter, setSourceFilter] = useState<SourceFilter>('all');
  const [form, setForm] = useState<WarmerConfig | null>(null);
  const [saving, setSaving] = useState(false);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = () =>
    getWarmer()
      .then((s) => {
        setStatus(s);
        // Don't clobber in-progress edits on the 30s refresh.
        setForm((f) => f ?? s.config);
      })
      .catch((e) => setError(String(e)));

  useEffect(() => {
    load();
    const t = setInterval(load, 30_000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    const loadVideo = () =>
      getVideoFlag()
        .then((v) => setVideoFlag({ enabled: v.config.enabled, updatedAt: v.updatedAt }))
        .catch((e) => setError(String(e)));
    loadVideo();
    const t = setInterval(loadVideo, 30_000);
    return () => clearInterval(t);
  }, []);

  const toggleVideo = async () => {
    if (!videoFlag || videoSaving) return;
    setVideoSaving(true);
    setError(null);
    try {
      const next = !videoFlag.enabled;
      await putVideoFlag(next);
      setVideoFlag({ enabled: next, updatedAt: new Date().toISOString() });
    } catch (e) {
      setError(String(e));
    } finally {
      setVideoSaving(false);
    }
  };

  useEffect(() => {
    const loadConns = () =>
      getConnections(sourceFilter)
        .then((r) => setConnections(r.connections))
        .catch((e) => setError(String(e)));
    loadConns();
    const t = setInterval(loadConns, 30_000);
    return () => clearInterval(t);
  }, [sourceFilter]);

  const save = async () => {
    if (!form) return;
    setSaving(true);
    setError(null);
    try {
      await putWarmer(form);
      setSavedAt(Date.now());
      await load();
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  };

  if (!status) return <div className="container muted">Loading…</div>;

  if (!status.schemaReady) {
    return (
      <div className="container">
        <div className="card muted">
          Warmer tables don't exist yet — deploy the backend with the fal warmer first.
        </div>
      </div>
    );
  }

  const s = status.stats24h;
  const billedUsd = s ? (s.billed_ms / 1000) * FAL_USD_PER_SEC : 0;
  const lastPing = status.pings[0];
  const state = warmerStateNow(status.config);

  return (
    <div className="container">
      <div className="section-title">Video generation (LTX idle-state animation)</div>
      <div className="stat-row">
        <div className="stat">
          <div className="label">Video generation</div>
          <div className="value">
            <span className={`pill ${videoFlag?.enabled ? 'warm' : 'fail'}`}>
              {videoFlag ? (videoFlag.enabled ? 'enabled' : 'disabled') : 'loading…'}
            </span>
          </div>
          <div className="sub">
            {videoFlag?.enabled
              ? 'video H100s launch on demand; animation UX visible in-app'
              : 'no video H100s will spin up (running ones drain in ~60s); animation UX hidden in-app'}
          </div>
        </div>
        <div className="stat">
          <div className="label">Kill switch</div>
          <div className="value">
            <button className="btn" onClick={toggleVideo} disabled={!videoFlag || videoSaving}>
              {videoSaving ? 'saving…' : videoFlag?.enabled ? 'Disable video' : 'Enable video'}
            </button>
          </div>
          <div className="sub">
            backend applies within ~60s
            {videoFlag?.updatedAt ? ` · last changed ${fmtAgo(videoFlag.updatedAt)}` : ''}
          </div>
        </div>
      </div>

      <div className="section-title">fal keep-warm — last 24h</div>
      <div className="stat-row">
        <div className="stat">
          <div className="label">Warmer</div>
          <div className="value">
            <span className={`pill ${state.cls}`}>{state.label}</span>
          </div>
          <div className="sub">
            {lastPing ? `last ping ${fmtAgo(lastPing.ts)}` : 'no pings yet'}
          </div>
        </div>
        <div className="stat">
          <div className="label">Pings</div>
          <div className="value">{s?.pings ?? 0}</div>
          <div className="sub">{s?.failures ?? 0} failed</div>
        </div>
        <div className="stat">
          <div className="label">Found cold</div>
          <div className="value">{s?.cold_encounters ?? 0}</div>
          <div className="sub">of {s?.pings ?? 0} pings</div>
        </div>
        <div className="stat">
          <div className="label">Est. billed</div>
          <div className="value">{fmtMs(s?.billed_ms ?? 0)}</div>
          <div className="sub">≈ ${billedUsd.toFixed(2)} / 24h — cold waits are unbilled</div>
        </div>
      </div>

      <div className="section-title">Warmer vs real users — all fal connections (24h)</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Source</th>
              <th>Connections</th>
              <th>Answered</th>
              <th>Cold</th>
              <th>Wait p50</th>
              <th>Wait p90</th>
              <th>Wait max</th>
            </tr>
          </thead>
          <tbody>
            {status.sources24h.map((r) => (
              <tr key={r.source}>
                <td>{r.source === 'user' ? 'real users' : 'warmer'}</td>
                <td>{r.conns}</td>
                <td>{r.answered}</td>
                <td>{r.cold > 0 ? <span className="pill cold">{r.cold}</span> : 0}</td>
                <td>{fmtMs(r.wait_p50)}</td>
                <td>{fmtMs(r.wait_p90)}</td>
                <td>{fmtMs(r.wait_max)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {status.sources24h.length === 0 && (
          <div className="muted" style={{ padding: 20 }}>
            No connection records yet — they accrue as the warmer pings and users draw.
          </div>
        )}
      </div>

      <div className="section-title">Controls</div>
      <div className="card">
        {form ? (
          <div style={{ display: 'flex', gap: 20, alignItems: 'flex-end', flexWrap: 'wrap' }}>
            <label style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <input
                type="checkbox"
                checked={form.enabled}
                onChange={(e) => setForm({ ...form, enabled: e.target.checked })}
              />
              Enabled
            </label>
            <label>
              <div className="muted">Interval (min)</div>
              <input
                type="number"
                min={1}
                max={60}
                value={Math.round(form.intervalMs / 60_000)}
                onChange={(e) =>
                  setForm({ ...form, intervalMs: Math.max(1, Number(e.target.value)) * 60_000 })
                }
                style={{ width: 90 }}
              />
            </label>
            <label>
              <div className="muted">Off from (hr, Pacific)</div>
              <input
                type="number"
                min={0}
                max={24}
                value={form.offStartHour}
                onChange={(e) => setForm({ ...form, offStartHour: Number(e.target.value) })}
                style={{ width: 90 }}
              />
            </label>
            <label>
              <div className="muted">Off until (hr, Pacific)</div>
              <input
                type="number"
                min={0}
                max={24}
                value={form.offEndHour}
                onChange={(e) => setForm({ ...form, offEndHour: Number(e.target.value) })}
                style={{ width: 90 }}
              />
            </label>
            <button onClick={save} disabled={saving}>
              {saving ? 'Saving…' : 'Save'}
            </button>
            {savedAt && Date.now() - savedAt < 5000 && <span className="muted">Saved ✓</span>}
          </div>
        ) : (
          <div className="muted">
            No config row yet — the backend seeds it on first boot with the warmer. Refresh after
            deploying.
          </div>
        )}
        <div className="muted" style={{ marginTop: 12, fontSize: 12 }}>
          The backend re-reads this every ~30s — changes apply without a redeploy. Off-window hours
          are America/Los_Angeles (DST-aware); equal values disable the window.
        </div>
        {error && <div style={{ color: '#ff7b72', marginTop: 8 }}>{error}</div>}
      </div>

      <div className="section-title">
        Request history (48h) —{' '}
        {(['all', 'user', 'warmer'] as SourceFilter[]).map((f) => (
          <button
            key={f}
            className="ghost"
            onClick={() => setSourceFilter(f)}
            style={{
              marginRight: 6,
              padding: '2px 10px',
              fontSize: 12,
              opacity: sourceFilter === f ? 1 : 0.5,
            }}
          >
            {f === 'all' ? 'All' : f === 'user' ? 'Users' : 'Warmer'}
          </button>
        ))}
      </div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Time</th>
              <th>Source</th>
              <th>User</th>
              <th>Result</th>
              <th>Wait</th>
              <th>Frames in/out</th>
              <th>Conn. open</th>
              <th>Close</th>
            </tr>
          </thead>
          <tbody>
            {connections.map((c, i) => (
              <tr key={`${c.opened_at}-${i}`}>
                <td className="muted">
                  {fmtAgo(c.opened_at)} <span className="mono">({fmtTime(c.opened_at)})</span>
                </td>
                <td>
                  <span className={`pill ${c.source === 'user' ? 'src-user' : ''}`}>{c.source}</span>
                </td>
                <td>
                  {c.source === 'warmer' ? (
                    <span className="muted">—</span>
                  ) : (
                    c.email ?? <span className="mono">{c.user_id?.slice(0, 8) ?? '?'}</span>
                  )}
                </td>
                <td>
                  {c.found_warm === null ? (
                    <span className="pill">no result</span>
                  ) : c.found_warm ? (
                    <span className="pill warm">warm</span>
                  ) : (
                    <span className="pill cold">cold</span>
                  )}
                </td>
                <td>{fmtMs(c.wait_ms)}</td>
                <td className="muted">
                  {c.frames_sent}/{c.frames_received}
                </td>
                <td>{fmtMs(c.open_ms)}</td>
                <td className="muted">{c.close_reason ?? ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {connections.length === 0 && (
          <div className="muted" style={{ padding: 20 }}>
            No connections recorded yet.
          </div>
        )}
      </div>
    </div>
  );
}
