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
import { getCapacity, getCapacityGrid, type CapacityData, type CapacityGridData } from '../api';

/** Mirrors the backend's LAMBDA_REGIONS (widened 2026-09-12) — "our H100
 * grid" for the joint / drought / dry-alternative views. Editable on the page
 * so a what-if (drop a region, add one) needs no deploy. */
const DEFAULT_GRID_REGIONS = 'us-southeast-1,us-south-2,us-east-1,us-west-3,us-south-3';

const fmtLocal = (iso: string | null | undefined): string =>
  iso ? new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
const fmtMin = (m: number | null | undefined): string =>
  m == null ? '—' : m >= 90 ? `${(m / 60).toFixed(1)}h` : `${m}m`;

/** Availability % → cell color (red drought → green plentiful). */
function heatColor(pct: number | null): string {
  if (pct == null) return 'transparent';
  const p = Math.max(0, Math.min(100, pct));
  const hue = (p / 100) * 130; // 0 = red, 130 = green
  return `hsl(${hue}, 65%, ${p === 0 ? 32 : 40}%)`;
}

export function Capacity() {
  const [data, setData] = useState<CapacityData | null>(null);
  const [grid, setGrid] = useState<CapacityGridData | null>(null);
  const [days, setDays] = useState(14);
  // The text box edits freely; `regions` (what we query with) only moves on
  // blur/Enter so every keystroke doesn't fire three window-function queries.
  const [regionsDraft, setRegionsDraft] = useState(DEFAULT_GRID_REGIONS);
  const [regions, setRegions] = useState(DEFAULT_GRID_REGIONS);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const load = () => {
      getCapacity(days).then(setData).catch((e) => setError(String(e)));
      getCapacityGrid(days, regions).then(setGrid).catch((e) => setError(String(e)));
    };
    load();
    const t = setInterval(load, 60_000);
    return () => clearInterval(t);
  }, [days, regions]);

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

      {/* ── Joint availability: "could the pool have found SOMETHING" per grid ── */}
      <SectionTitle
        title="Joint availability — % of polls with ≥1 advertised cell"
        nav="Joint availability"
        right={
          <label style={{ fontSize: 12, display: 'flex', alignItems: 'center', gap: 6 }}>
            <span className="muted">our regions</span>
            <input
              value={regionsDraft}
              onChange={(e) => setRegionsDraft(e.target.value)}
              onBlur={() => setRegions(regionsDraft)}
              onKeyDown={(e) => { if (e.key === 'Enter') setRegions(regionsDraft); }}
              spellCheck={false}
              style={{ fontSize: 12, padding: '4px 8px', width: 360, fontFamily: 'monospace' }}
            />
          </label>
        }
      />
      {!grid ? (
        <div className="card muted">Loading…</div>
      ) : (
        <>
          <div className="card" style={{ padding: 0 }}>
            <table>
              <thead>
                <tr><th>Grid</th><th>Cells</th><th>% of polls with capacity</th><th>Polls</th></tr>
              </thead>
              <tbody>
                {grid.grids.map((g) => (
                  <tr key={g.key}>
                    <td><strong>{g.label}</strong></td>
                    <td className="muted" style={{ fontSize: 12 }}>
                      {g.types.map((t) => t.replace('gpu_1x_', '')).join(' / ')}
                      {' × '}
                      {g.regions ? g.regions.join(', ') : 'any region'}
                    </td>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div style={{ width: 160, height: 8, background: '#3a3a3a', borderRadius: 4, overflow: 'hidden' }}>
                          <div style={{ width: `${g.pct ?? 0}%`, height: '100%', background: heatColor(g.pct) }} />
                        </div>
                        <span className="monospace" style={{ fontSize: 12 }}>{g.pct == null ? '—' : `${g.pct}%`}</span>
                      </div>
                    </td>
                    <td className="muted" style={{ fontSize: 12 }}>{g.available_ticks} / {grid.ticks}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
            A poll counts if ANY cell in the grid advertised capacity — the pool's sweep needs only one.
            <strong> Our H100 grid</strong> = what the image pool actually hunts (1x H100 sxm5/pcie in
            the configured regions; edit the list above for a what-if). The A100 rows show what widening
            the fallback list buys; "any region" rows show what widening <code>LAMBDA_REGIONS</code> buys.
          </div>

          {/* ── Droughts: consecutive dry polls of our H100 grid ── */}
          <SectionTitle title="Droughts — runs of polls where our H100 grid had nothing" nav="Droughts" />
          <div className="stat-row">
            <div className="stat">
              <div className="label">Droughts</div>
              <div className="value">{grid.droughts.count}</div>
              <div className="sub">{grid.droughts.dry_ticks} dry polls of {grid.ticks}</div>
            </div>
            <div className="stat">
              <div className="label">Longer than 30 min</div>
              <div className="value">{grid.droughts.over_30m}</div>
              <div className="sub">a hedge-length boot can't hide these</div>
            </div>
            <div className="stat">
              <div className="label">Drought length</div>
              <div className="value">{fmtMin(grid.droughts.p50_minutes)}</div>
              <div className="sub">p50 · worst {fmtMin(grid.droughts.max_minutes)}</div>
            </div>
          </div>
          <div className="card" style={{ padding: 0, marginTop: 12 }}>
            <table>
              <thead>
                <tr><th>Started (local)</th><th>Capacity back</th><th>Length</th><th>Dry polls</th></tr>
              </thead>
              <tbody>
                {grid.droughts.top.map((d) => (
                  <tr key={d.started_at}>
                    <td style={{ whiteSpace: 'nowrap' }}>{fmtLocal(d.started_at)}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>
                      {d.ongoing ? <span className="pill fail">still dry</span> : fmtLocal(d.ended_at)}
                    </td>
                    <td><strong>{fmtMin(d.minutes)}</strong></td>
                    <td className="muted">{d.ticks}</td>
                  </tr>
                ))}
                {grid.droughts.top.length === 0 && (
                  <tr><td colSpan={4} className="muted">No dry polls in this window — the grid always had something advertised.</td></tr>
                )}
              </tbody>
            </table>
          </div>
          <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
            Top 15 by length. A drought runs from its first dry poll to the poll where capacity reappeared
            (~2 min granularity). Advertised-capacity droughts, not launch failures — Fleet has those.
          </div>

          {/* ── Dry-tick alternatives: the fallback menu ── */}
          <SectionTitle title="What's available when our grid is dry" nav="When dry" />
          <div className="card" style={{ padding: 0 }}>
            <table>
              <thead>
                <tr><th>Instance type</th><th>Region</th><th>% of dry polls advertised</th></tr>
              </thead>
              <tbody>
                {grid.dry_alternatives.map((a) => (
                  <tr key={`${a.instance_type}@${a.region}`}>
                    <td><strong>{a.instance_type.replace('gpu_1x_', '')}</strong></td>
                    <td>{a.region}</td>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div style={{ width: 160, height: 8, background: '#3a3a3a', borderRadius: 4, overflow: 'hidden' }}>
                          <div style={{ width: `${a.pct}%`, height: '100%', background: heatColor(a.pct) }} />
                        </div>
                        <span className="monospace" style={{ fontSize: 12 }}>{a.pct}% <span className="muted">({a.ticks} / {grid.droughts.dry_ticks})</span></span>
                      </div>
                    </td>
                  </tr>
                ))}
                {grid.dry_alternatives.length === 0 && (
                  <tr><td colSpan={3} className="muted">
                    {grid.droughts.dry_ticks === 0 ? 'The grid was never dry in this window.' : 'Nothing else was advertised either — total droughts.'}
                  </td></tr>
                )}
              </tbody>
            </table>
          </div>
          <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
            Of the {grid.droughts.dry_ticks} polls where our H100 grid had nothing, the share in which each
            other H100/A100 cell (any region) WAS advertised — i.e. what a fallback would have found. Top 12.
          </div>
        </>
      )}
    </div>
  );
}
