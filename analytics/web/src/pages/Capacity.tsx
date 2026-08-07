/**
 * GPU Capacity — Lambda ADVERTISED availability over time, from the backend's
 * free /instance-types heartbeat (~2 min). Answers "how gettable are the GPUs
 * we fall back through, and when do the droughts hit."
 *
 * Honesty is the design constraint: this is Lambda's capacity FLAG, which has
 * no depth (1 vs 100 GPUs both read "available") and can be stale by seconds.
 * It is NOT a reservation. The banner says so, and every number is framed as
 * "% of polls that showed capacity," never "you will get one." Ground truth
 * for actual acquisition lives on the Fleet tab (real launch outcomes).
 */
import { useEffect, useState } from 'react';
import { SectionTitle } from '../PageNav';
import { getCapacity, type CapacityData } from '../api';

/** Availability % → cell color (red drought → green plentiful). */
function heatColor(pct: number | null): string {
  if (pct == null) return 'transparent';
  const p = Math.max(0, Math.min(100, pct));
  const hue = (p / 100) * 130; // 0 = red, 130 = green
  return `hsl(${hue}, 65%, ${p === 0 ? 32 : 40}%)`;
}

export function Capacity() {
  const [data, setData] = useState<CapacityData | null>(null);
  const [days, setDays] = useState(7);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const load = () => getCapacity(days).then(setData).catch((e) => setError(String(e)));
    load();
    const t = setInterval(load, 60_000);
    return () => clearInterval(t);
  }, [days]);

  if (error) return <div className="container"><div className="card fail">{error}</div></div>;
  if (!data) return <div className="container muted">Loading…</div>;

  if (!data.schemaReady) {
    return (
      <div className="container">
        <div className="card muted">
          Capacity tables don't exist yet — deploy the backend with the capacity monitor first.
        </div>
      </div>
    );
  }

  const types = [...new Set(data.cells.map((c) => c.instance_type))].sort();
  const hours = Array.from({ length: 24 }, (_, i) => i);
  const heatByType = new Map<string, Map<number, number>>();
  for (const h of data.heatmap) {
    if (!heatByType.has(h.instance_type)) heatByType.set(h.instance_type, new Map());
    heatByType.get(h.instance_type)!.set(h.hod, h.pct);
  }

  const tickCount = data.ticks.ticks;
  const spanNote = data.ticks.first_at && data.ticks.last_at
    ? `${tickCount} polls over ${Math.round((new Date(data.ticks.last_at).getTime() - new Date(data.ticks.first_at).getTime()) / 3_600_000)}h`
    : `${tickCount} polls`;

  return (
    <div className="container">
      <SectionTitle
        title="GPU capacity — advertised availability"
        nav="Advertised availability"
        right={
          <select value={days} onChange={(e) => setDays(Number(e.target.value))}
            style={{ fontSize: 13, padding: '4px 8px' }}>
            <option value={1}>last 24h</option>
            <option value={3}>last 3 days</option>
            <option value={7}>last 7 days</option>
            <option value={14}>last 14 days</option>
          </select>
        }
      />

      <div className="card" style={{ borderLeft: '3px solid var(--accent, #888)', fontSize: 13 }}>
        <strong>What this is:</strong> the free <code>/instance-types</code> poll (~every 2 min) —
        Lambda's <em>advertised</em> capacity flag. It has no depth (1 vs 100 GPUs both read
        "available") and can be stale by seconds, so a cell showing capacity can still fail an
        actual launch. Treat these as <strong>trends, not guarantees</strong>. For whether users
        actually got a GPU (and how long they waited), see the <strong>GPU Fleet</strong> tab.
        <span className="muted"> · {spanNote}</span>
      </div>

      {/* Headline: current + windowed availability per (type, region). */}
      <SectionTitle title="Availability by type &amp; region" nav="By type &amp; region" />
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Instance type</th><th>Region</th><th>% of polls available</th>
              <th>Last seen</th>
            </tr>
          </thead>
          <tbody>
            {data.cells.map((c, i) => (
              <tr key={i}>
                <td><strong>{c.instance_type.replace('gpu_1x_', '')}</strong></td>
                <td>{c.region}</td>
                <td>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <div style={{ width: 120, height: 8, background: '#3a3a3a', borderRadius: 4, overflow: 'hidden' }}>
                      <div style={{ width: `${c.pct}%`, height: '100%', background: heatColor(c.pct) }} />
                    </div>
                    <span className="monospace" style={{ fontSize: 12 }}>{c.pct}%</span>
                  </div>
                </td>
                <td className="muted" style={{ fontSize: 12 }}>
                  {c.last_available ? new Date(c.last_available).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—'}
                </td>
              </tr>
            ))}
            {data.cells.length === 0 && (
              <tr><td colSpan={4} className="muted">No capacity seen for any tracked type in this window — a total drought, or the monitor just started.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        Types tracked = the pool's image + video fallback lists. A type absent from this table had
        zero advertised capacity anywhere in the window.
      </div>

      {/* Time-of-day heatmap: when do droughts hit? */}
      <SectionTitle title="Availability by hour of day (Pacific)" nav="By hour of day" />
      <div className="card" style={{ overflowX: 'auto' }}>
        <table style={{ borderCollapse: 'collapse', fontSize: 11 }}>
          <thead>
            <tr>
              <th style={{ textAlign: 'left', paddingRight: 8 }}>type \ hour</th>
              {hours.map((h) => <th key={h} style={{ width: 22, textAlign: 'center', fontWeight: 400 }}>{h}</th>)}
            </tr>
          </thead>
          <tbody>
            {types.map((t) => (
              <tr key={t}>
                <td style={{ paddingRight: 8, whiteSpace: 'nowrap' }}>{t.replace('gpu_1x_', '')}</td>
                {hours.map((h) => {
                  const pct = heatByType.get(t)?.get(h);
                  return (
                    <td key={h} title={pct != null ? `${h}:00 — ${pct}%` : `${h}:00 — no data`}
                      style={{ width: 22, height: 22, background: heatColor(pct ?? null), textAlign: 'center', color: '#fff' }}>
                      {pct != null ? pct : ''}
                    </td>
                  );
                })}
              </tr>
            ))}
            {types.length === 0 && <tr><td className="muted">No data yet.</td></tr>}
          </tbody>
        </table>
        <div className="muted" style={{ fontSize: 11, marginTop: 6 }}>
          Each cell = % of polls in that Pacific hour (across all days in the window) where the type
          had capacity in ANY region — i.e. what the pool's cross-region sweep effectively sees.
          Red = drought.
        </div>
      </div>
    </div>
  );
}
