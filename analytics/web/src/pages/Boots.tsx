/**
 * Boots — the dedicated boot-success + boot-timing view for one GPU pool
 * (image by default; the video pool is one toggle away).
 *
 * Complements GPU Fleet: Fleet answers "are USERS getting GPUs", this page
 * answers "what does each BOOT cost us and where does the time go". Reading
 * order:
 *   1. Success + headline timings (30d)
 *   2. Where the time goes — Lambda's share vs ours (decomposition medians)
 *   3. Every boot, decomposed (stacked bar per boot + expandable phases)
 *   4. Which init phase dominates our stack
 *   5. Daily trend
 *
 * Decomposition source: the backend pool stamps every `ready` event's detail
 * with {provision_s, os_s, stack_s, phases_ms} from the server's own /health
 * clocks (since 2026-08-22). Older boots show totals only.
 */
import { useEffect, useState } from 'react';
import { getBootCells, getBoots, type BootCellsData, type BootRow, type BootsData } from '../api';

const fmtMin = (m: number | null | undefined): string =>
  m == null ? '—' : m >= 90 ? `${(m / 60).toFixed(1)}h` : `${m}m`;
import { SectionTitle } from '../PageNav';

const fmtS = (s: number | null | undefined): string =>
  s == null ? '—' : s >= 90 ? `${(s / 60).toFixed(1)}m` : `${Math.round(s)}s`;
const fmtMs = (ms: number | null | undefined): string => (ms == null ? '—' : fmtS(ms / 1000));

const OUTCOME_CLS: Record<string, string> = {
  ready: 'warm',
  booting: 'cold',
  hedge_lost: 'cold',
  boot_stalled: 'fail',
  launch_failed: 'fail',
  sweep_abandoned: 'fail',
  unknown: 'cold',
};

const OUTCOME_LABEL: Record<string, string> = {
  ready: 'ready',
  booting: 'booting now…',
  hedge_lost: 'lost hedge race',
  boot_stalled: 'stalled (25m timeout)',
  launch_failed: 'no capacity',
  sweep_abandoned: 'hunt abandoned',
  unknown: 'no terminal event',
};

/** Human labels for the phase_timings_ms keys worth reading. */
const PHASE_LABEL: Record<string, string> = {
  warmup_inference_ms: 'warmup (compile shapes)',
  warmup_ref1_ms: 'warmup (1-ref serving shape)',
  warmup_ref2_ms: 'bg 2-ref warmup (post-ready)',
  from_pretrained_ms: 'model load',
  prefetch_total_ms: 'weight prefetch (overlapped)',
  prefetch_wait_ms: 'prefetch wait (critical path)',
  transformer_build_ms: 'transformer build',
  gemma_build_ms: 'Gemma build',
  imports_ms: 'python imports',
  pipeline_init_ms: 'pipeline init',
  resolve_paths_ms: 'path resolve',
};

/** provision | os | stack stacked bar, scaled against the slowest boot. */
function BootBar({ b, maxMs }: { b: BootRow; maxMs: number }) {
  if (b.boot_ms == null) return null;
  const widthPct = Math.max(3, (b.boot_ms / maxMs) * 100);
  const segs =
    b.provision_s != null && b.stack_s != null
      ? [
          { label: 'provision', s: b.provision_s, color: '#b3661f' },
          { label: 'os', s: b.os_s ?? 0, color: '#6b7280' },
          { label: 'stack', s: b.stack_s, color: '#2f7d4f' },
        ]
      : [{ label: 'boot (undecomposed)', s: b.boot_ms / 1000, color: '#6b7280' }];
  const total = segs.reduce((a, x) => a + x.s, 0) || 1;
  return (
    <div style={{ display: 'flex', width: `${widthPct}%`, minWidth: 60, height: 14, borderRadius: 3, overflow: 'hidden' }}>
      {segs.map((x) => (
        <div
          key={x.label}
          title={`${x.label}: ${fmtS(x.s)}`}
          style={{ width: `${(x.s / total) * 100}%`, background: x.color }}
        />
      ))}
    </div>
  );
}

export function Boots() {
  const [pool, setPool] = useState<'image' | 'video'>('image');
  const [data, setData] = useState<BootsData | null>(null);
  const [cells, setCells] = useState<BootCellsData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);

  useEffect(() => {
    setData(null);
    const load = () => {
      getBoots(pool).then(setData).catch((e) => setError(String(e)));
      getBootCells().then(setCells).catch((e) => setError(String(e)));
    };
    load();
    const t = setInterval(load, 30_000);
    return () => clearInterval(t);
  }, [pool]);

  if (error) return <div className="container"><div className="card fail">{error}</div></div>;
  if (!data) return <div className="container muted">Loading…</div>;

  const s = data.summary;
  const readyRows = data.boots.filter((b) => b.outcome === 'ready');
  const maxMs = Math.max(...readyRows.map((b) => b.boot_ms ?? 0), 1);
  const grantRate = s.hunts ? Math.round((s.granted / s.hunts) * 100) : null;
  const readyRate = s.granted ? Math.round((s.ready / s.granted) * 100) : null;

  return (
    <div className="container">
      <SectionTitle
        title={`${pool === 'image' ? 'Image' : 'Video'} boots — last 30 days`}
        nav="Overview"
        right={
          <span style={{ display: 'flex', gap: 6 }}>
            {(['image', 'video'] as const).map((k) => (
              <button
                key={k}
                className={pool === k ? '' : 'ghost'}
                style={{ fontSize: 13, padding: '4px 10px' }}
                onClick={() => setPool(k)}
              >
                {k}
              </button>
            ))}
          </span>
        }
      />

      {/* ── 1: success + headline timings ── */}
      <div className="stat-row">
        <div className="stat">
          <div className="label">Boot success</div>
          <div className="value">{readyRate == null ? '—' : `${readyRate}%`}</div>
          <div className="sub">
            {s.ready} ready of {s.granted} GPUs granted ({s.hunts} hunts, {grantRate ?? '—'}% got capacity)
            {s.booting_now > 0 ? ` · ${s.booting_now} booting now` : ''}
          </div>
        </div>
        <div className="stat">
          <div className="label">Boot time (granted → serving)</div>
          <div className="value">{fmtMs(s.boot_p50_ms)}</div>
          <div className="sub">p90 {fmtMs(s.boot_p90_ms)} · worst {fmtMs(s.boot_max_ms)}</div>
        </div>
        <div className="stat">
          <div className="label">Lambda's share vs ours</div>
          <div className="value">
            {fmtS(s.provision_p50_s)} <span className="muted" style={{ fontSize: 14 }}>/</span> {fmtS(s.stack_p50_s)}
          </div>
          <div className="sub">
            provision p50 / our-stack p50 ({s.decomposed} of {s.ready} boots decomposed) · worst provision {fmtS(s.provision_max_s)}
          </div>
        </div>
        <div className="stat">
          <div className="label">Hedge races</div>
          <div className="value">{s.hedges_fired}</div>
          <div className="sub">
            {s.hedges_fired === 0
              ? 'none fired (no boot dragged past the threshold)'
              : `${s.hedge_wins} won by the hedge · ${s.hedge_losses} originals lost`}
          </div>
        </div>
      </div>

      {/* ── failure strip: why boots didn't complete ── */}
      {(s.stalled > 0 || s.failed > 0 || s.abandoned > 0) && (
        <div className="card" style={{ fontSize: 13 }}>
          <strong>Losses:</strong>{' '}
          {s.failed > 0 && <span className="pill fail" style={{ marginRight: 6 }}>{s.failed} no-capacity</span>}
          {s.abandoned > 0 && <span className="pill fail" style={{ marginRight: 6 }}>{s.abandoned} hunts abandoned (user left)</span>}
          {s.stalled > 0 && <span className="pill fail">{s.stalled} stalled at the 25m boot timeout</span>}
        </div>
      )}

      {/* ── 3: every boot, decomposed ── */}
      <SectionTitle title="Every boot, decomposed" nav="Every boot" />
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>When</th><th>Outcome</th><th>Search</th><th>Total boot</th>
              <th style={{ width: '30%' }}>provision · os · stack</th><th>Lambda / ours</th><th>Notes</th>
            </tr>
          </thead>
          <tbody>
            {data.boots.map((b) => (
              <tr
                key={b.instance_name}
                onClick={() => setExpanded(expanded === b.instance_name ? null : b.instance_name)}
                style={{ cursor: b.phases_ms ? 'pointer' : undefined }}
              >
                <td style={{ whiteSpace: 'nowrap' }}>
                  {new Date(b.requested_at).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}
                </td>
                <td>
                  <span className={`pill ${OUTCOME_CLS[b.outcome] ?? ''}`}>{OUTCOME_LABEL[b.outcome] ?? b.outcome}</span>
                  {b.is_hedge && <span className="pill cold" style={{ marginLeft: 4 }}>hedge{b.hedge_won ? ' ✓won' : ''}</span>}
                  {b.hedged && <span className="pill cold" style={{ marginLeft: 4 }}>was hedged</span>}
                </td>
                <td>{fmtMs(b.search_ms)}</td>
                <td><strong>{fmtMs(b.boot_ms)}</strong></td>
                <td>{b.outcome === 'ready' ? <BootBar b={b} maxMs={maxMs} /> : <span className="muted">—</span>}</td>
                <td style={{ whiteSpace: 'nowrap' }}>
                  {b.provision_s != null
                    ? <>{fmtS(b.provision_s)} / {fmtS(b.stack_s)}</>
                    : <span className="muted">{b.outcome === 'ready' ? 'pre-instrumentation' : '—'}</span>}
                </td>
                <td className="muted" style={{ fontSize: 12, maxWidth: 260, overflow: 'hidden', textOverflow: 'ellipsis' }}>
                  {b.gpu_type?.replace('gpu_1x_', '') ?? ''}{b.region ? `@${b.region}` : ''}
                  {b.fail_detail ? ` · ${b.fail_detail}` : ''}
                </td>
              </tr>
            ))}
            {data.boots.length === 0 && (
              <tr><td colSpan={7} className="muted">No boots in the last 30 days.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      {expanded && (() => {
        const b = data.boots.find((x) => x.instance_name === expanded);
        if (!b?.phases_ms) return null;
        const entries = Object.entries(b.phases_ms)
          .filter(([k, v]) => k.endsWith('_ms') && typeof v === 'number' && v > 500)
          .sort(([, a], [, c]) => (c as number) - (a as number));
        return (
          <div className="card" style={{ marginTop: 8, fontSize: 13 }}>
            <strong className="monospace">{b.instance_name}</strong> — init phases:
            <table style={{ marginTop: 6 }}>
              <tbody>
                {entries.map(([k, v]) => (
                  <tr key={k}>
                    <td>{PHASE_LABEL[k] ?? k}</td>
                    <td><strong>{fmtMs(v as number)}</strong></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        );
      })()}
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        One row per capacity hunt, newest first — click a ready row for its init-phase breakdown.
        <strong> provision</strong> (amber) = Lambda's VM provisioning (capacity granted → kernel boot) — a
        per-VM lottery measured at 2–14 min for identical launches; nothing we run can shorten it, the hedge
        races around it. <strong>stack</strong> (green) = our boot (venv → weight load → compile → warmup).
        Search = capacity hunt before the boot even starts (capacity-bound). Decomposition exists for boots
        since 2026-08-22; older ready rows show the total only.
      </div>

      {/* ── 4: which phase dominates our stack ── */}
      {data.phase_medians.length > 0 && (
        <>
          <SectionTitle title="Inside our stack — init phase medians" nav="Init phases" />
          <div className="card" style={{ padding: 0 }}>
            <table>
              <thead>
                <tr><th>Phase</th><th>p50</th><th>Boots measured</th></tr>
              </thead>
              <tbody>
                {data.phase_medians.map((ph) => (
                  <tr key={ph.phase}>
                    <td>{PHASE_LABEL[ph.phase] ?? ph.phase}</td>
                    <td><strong>{fmtMs(ph.p50_ms)}</strong></td>
                    <td className="muted">{ph.n}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
            The optimization target list for the controllable part of the boot. "prefetch (overlapped)" runs
            concurrently with imports — only "prefetch wait" is critical path.
          </div>
        </>
      )}

      {/* ── 5: daily trend ── */}
      <SectionTitle title="Daily trend" nav="Daily trend" />
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr><th>Day</th><th>Boots ready</th><th>Boot p50</th><th>Provision p50</th><th>Our stack p50</th></tr>
          </thead>
          <tbody>
            {data.daily.map((d) => (
              <tr key={d.day}>
                <td>{d.day}</td>
                <td>{d.boots}</td>
                <td>{fmtMs(d.boot_p50_ms)}</td>
                <td>{fmtS(d.provision_p50_s)}</td>
                <td>{fmtS(d.stack_p50_s)}</td>
              </tr>
            ))}
            {data.daily.length === 0 && <tr><td colSpan={5} className="muted">No ready boots yet.</td></tr>}
          </tbody>
        </table>
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        If boot p50 moves while "our stack p50" holds flat, the regression is Lambda-side (provisioning or
        capacity) — check the Capacity page. If "our stack" moves, something in model-servers or the
        filesystem changed — check the phase medians above and recent syncs.
      </div>

      {/* ── 6: per-cell boot time (both pools) ── */}
      <SectionTitle title="Per-cell boot time — is the lottery per cell?" nav="Per-cell boot time" />
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr><th>Pool</th><th>Instance type</th><th>Region</th><th>Boots</th><th>p50</th><th>p90</th><th>Worst</th></tr>
          </thead>
          <tbody>
            {(cells?.cells ?? []).map((c) => (
              <tr key={`${c.pool}/${c.instance_type}@${c.region}`} style={{ opacity: c.pool === pool ? 1 : 0.6 }}>
                <td><span className="pill">{c.pool}</span></td>
                <td><strong>{c.instance_type.replace('gpu_1x_', '')}</strong></td>
                <td>{c.region}</td>
                <td>{c.boots}</td>
                <td><strong>{fmtMin(c.p50_min)}</strong></td>
                <td>{fmtMin(c.p90_min)}</td>
                <td>{fmtMin(c.max_min)}</td>
              </tr>
            ))}
            {cells && cells.cells.length === 0 && (
              <tr><td colSpan={7} className="muted">No launched→ready pairs in the last {cells.days} days.</td></tr>
            )}
            {!cells && <tr><td colSpan={7} className="muted">Loading…</td></tr>}
          </tbody>
        </table>
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        Both pools, last {cells?.days ?? 30} days — the current pool's rows are highlighted. Boot = capacity
        granted → /health ok (the <code>ready</code> event's duration), joined to the <code>launched</code>
        event's <code>type@region</code> by instance name. Boots that never reached ready aren't here (see
        the losses strip above). A cell whose p50 sits far above the others is where Lambda's provisioning
        lottery lives — prefer the cheap cells in the region sweep order.
      </div>

      {/* ── 7: hedge outcomes ── */}
      <SectionTitle title="Hedge outcomes" nav="Hedge outcomes" />
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr><th>Pool</th><th>Hedges launched</th><th>Resolved</th><th>Hedge won</th><th>Original won</th><th>Hedge win rate</th></tr>
          </thead>
          <tbody>
            {(cells?.hedges ?? []).map((h) => (
              <tr key={h.pool} style={{ opacity: h.pool === pool ? 1 : 0.6 }}>
                <td><span className="pill">{h.pool}</span></td>
                <td><strong>{h.launched}</strong></td>
                <td>
                  {h.resolved}
                  {h.resolved === 0 && h.legacy_loser_terminates > 0 && (
                    <span className="muted" style={{ fontSize: 12 }}> · {h.legacy_loser_terminates} settled pre-instrumentation</span>
                  )}
                </td>
                <td>{h.hedge_wins}</td>
                <td>{h.original_wins}</td>
                <td>{h.win_rate_pct == null ? <span className="muted">— (no resolved races yet)</span> : <strong>{h.win_rate_pct}%</strong>}</td>
              </tr>
            ))}
            {!cells && <tr><td colSpan={6} className="muted">Loading…</td></tr>}
          </tbody>
        </table>
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        A hedge fires when the oldest boot drags past the threshold with nothing ready (<code>hedge_launched</code>);
        <code>hedge_resolved</code> (recorded since 2026-09-12) says which racer reached ready first. A win rate
        near 50% means provisioning really is per-VM luck and the hedge is paying for itself; near 0% means the
        original usually finishes first and the hedge threshold is too eager. Races before instrumentation only
        left a loser-terminate event, counted as "settled pre-instrumentation".
      </div>
    </div>
  );
}
