/**
 * GPU Fleet — the user-experienced quality of both H100 systems, plus the
 * fleet lifecycle behind it.
 *
 * Reading order mirrors the operator's questions, top to bottom:
 *   1. Are users getting GPUs? (acquisition cards, image | video)
 *   2. How long did they wait? (wait percentiles, in the same cards)
 *   3. How good is it once they're on? (gen times, render ratio, stability)
 *   4. What has the fleet been doing? (lifecycle counts + raw event strip)
 *   5. Is it getting better or worse? (14-day daily trend)
 *
 * Orchestration is VARIABLE by design (capacity-bound searches, idle reaps,
 * kill-switch drains) — so every rate is shown with its denominator, and the
 * event strip keeps the raw truth one glance away from the aggregates.
 */
import { useEffect, useState } from 'react';
import { getFleet, getLivePods, type FleetData, type LivePodsData, type LivePoolState } from '../api';

const fmtMs = (v: number | null | undefined): string =>
  v == null ? '—' : v >= 10_000 ? `${Math.round(v / 1000)}s` : v >= 1000 ? `${(v / 1000).toFixed(1)}s` : `${v}ms`;

const pct = (num: number | undefined, den: number | undefined): string =>
  !den ? '—' : `${Math.round(((num ?? 0) / den) * 100)}%`;

/** Plain-language "why they didn't get one" per pool status at close. */
const MISS_STATUS_LABEL: Record<string, string> = {
  launching: 'still hunting capacity when they left',
  booting: 'GPU found, still warming when they left',
  none: 'pool idle / not trying',
  error: 'pool error',
  disabled: 'pool disabled (flag/env)',
  ready: 'WAS ready — session stayed on fal (no mid-session upgrade)',
  untracked: 'predates status tracking',
};

/** Event → pill class: good (green), transitional (amber), bad (red). */
const EVENT_CLS: Record<string, string> = {
  ready: 'warm',
  launched: 'warm',
  adopted: 'warm',
  launch_requested: 'cold',
  idle_terminate: 'cold',
  disabled_terminate: 'cold',
  launch_failed: 'fail',
  instance_dead: 'fail',
  boot_stalled: 'fail',
  sweep_abandoned: 'fail',
};

export function Fleet() {
  const [data, setData] = useState<FleetData | null>(null);
  const [pods, setPods] = useState<LivePodsData | null>(null);
  const [excludeTest, setExcludeTest] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const load = () =>
      getFleet(excludeTest)
        .then(setData)
        .catch((e) => setError(String(e)));
    load();
    const t = setInterval(load, 30_000);
    return () => clearInterval(t);
  }, [excludeTest]);

  useEffect(() => {
    const loadPods = () => getLivePods().then(setPods).catch(() => setPods({ backendReachable: false }));
    loadPods();
    const t = setInterval(loadPods, 15_000);
    return () => clearInterval(t);
  }, []);

  if (error) return <div className="container"><div className="card fail">{error}</div></div>;
  if (!data) return <div className="container muted">Loading…</div>;

  const img = data.image;
  const vid = data.video;
  const imgRatio = img?.sketches_sent ? (img.frames_delivered / img.sketches_sent) : null;
  const h100Ratio = img?.h100_sketches_sent ? (img.h100_frames_delivered / img.h100_sketches_sent) : null;

  return (
    <div className="container">
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div className="section-title">GPU fleet — last 7 days</div>
        <label style={{ display: 'flex', gap: 6, alignItems: 'center', fontSize: 13, cursor: 'pointer' }}>
          <input type="checkbox" checked={excludeTest} onChange={(e) => setExcludeTest(e.target.checked)} />
          Exclude test accounts
        </label>
      </div>

      {/* ── 0: live pods — what's running RIGHT NOW and why ── */}
      <div className="section-title">Live pods — why is each one up?</div>
      {!pods ? (
        <div className="card muted">Loading…</div>
      ) : !pods.backendReachable ? (
        <div className="card muted">Backend unreachable for live state (deploy in flight?) — historical sections below are unaffected.</div>
      ) : (
        <LivePoolCards image={pods.image} video={pods.video} />
      )}

      {/* ── 1+2: acquisition + waits, one card per system ── */}
      <div className="section-title">Do users get a GPU — and how long do they wait?</div>
      <div className="stat-row">
        <div className="stat">
          <div className="label">Image · sessions on the H100</div>
          <div className="value">{pct(img?.wired, img?.requested)}</div>
          <div className="sub">
            {img?.wired ?? 0} of {img?.requested ?? 0} that wanted one · {img?.framed ?? 0} saw ≥1 H100 frame
            {(img?.sessions ?? 0) > (img?.requested ?? 0)
              ? ` · ${(img?.sessions ?? 0) - (img?.requested ?? 0)} pinned fal`
              : ''}
          </div>
        </div>
        <div className="stat">
          <div className="label">Image · wait for the H100</div>
          <div className="value">{fmtMs(img?.wait_p50_ms)}</div>
          <div className="sub">
            p90 {fmtMs(img?.wait_p90_ms)} · first frame p50 {fmtMs(img?.first_frame_p50_ms)}
          </div>
        </div>
        <div className="stat">
          <div className="label">Video · sessions with an animation</div>
          <div className="value">{pct(vid?.sessions_delivered, vid?.video_sessions)}</div>
          <div className="sub">
            {vid?.sessions_delivered ?? 0} of {vid?.video_sessions ?? 0} video-path sessions · {vid?.videos_delivered ?? 0}/{vid?.videos_triggered ?? 0} videos delivered
          </div>
        </div>
        <div className="stat">
          <div className="label">Video · wait for an animation</div>
          <div className="value">{fmtMs(vid?.wait_p50_ms)}</div>
          <div className="sub">
            p90 {fmtMs(vid?.wait_p90_ms)} · trigger → on-screen ({vid?.manual_count ?? 0} manual)
          </div>
        </div>
      </div>

      {/* ── 2b: the misses — who wanted an H100 and never got one, and why ── */}
      <div className="section-title">Who didn't get an H100 — and why</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Pool was…</th><th>Sessions</th><th>Waited p50 / max</th><th>GPU arrived mid-session</th>
            </tr>
          </thead>
          <tbody>
            {(data.h100_misses ?? []).map((m) => (
              <tr key={m.pool_status}>
                <td>
                  <span className={`pill ${m.pool_status === 'ready' ? 'warm' : m.pool_status === 'error' ? 'fail' : 'cold'}`}>{m.pool_status}</span>
                  <span className="muted" style={{ fontSize: 12, marginLeft: 6 }}>{MISS_STATUS_LABEL[m.pool_status] ?? ''}</span>
                </td>
                <td>{m.sessions}</td>
                <td>{fmtMs(m.waited_p50_ms)} / {fmtMs(m.waited_max_ms)}</td>
                <td>{m.pool_ready_mid_session > 0 ? `${m.pool_ready_mid_session} (stayed on fal — auto never upgrades mid-session)` : '—'}</td>
              </tr>
            ))}
            {(data.h100_misses ?? []).length === 0 && (
              <tr><td colSpan={4} className="muted">No H100 misses in the last 7 days.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        Every session that asked for an H100 and closed without ever being wired to one. "Waited" is the
        whole session duration — for a never-wired session that IS the wait. Status columns land with the
        2026-07-25 backend; older rows group under their at-resolve status or "untracked".
      </div>
      {(data.recent_misses ?? []).length > 0 && (
        <div className="card" style={{ padding: 0, marginTop: 8 }}>
          <table>
            <thead>
              <tr>
                <th>When</th><th>Who</th><th>Waited</th><th>Pool at open → close</th><th>GPU during session</th><th>Client</th>
              </tr>
            </thead>
            <tbody>
              {data.recent_misses.map((m, i) => (
                <tr key={i}>
                  <td style={{ whiteSpace: 'nowrap' }}>{new Date(m.occurred_at).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</td>
                  <td className="muted" style={{ fontSize: 12 }}>{m.email ?? '?'}</td>
                  <td><strong>{fmtMs(m.duration_ms)}</strong></td>
                  <td>{m.at_resolve ?? '?'} → {m.at_close ?? '?'}</td>
                  <td>{m.ready_after_ms != null ? `ready after ${fmtMs(m.ready_after_ms)} (not picked up)` : 'never ready'}</td>
                  <td className="muted" style={{ fontSize: 12, maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis' }}>{m.client ?? ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* ── 3: quality once they're on ── */}
      <div className="section-title">Quality once they're on it</div>
      <div className="stat-row">
        <div className="stat">
          <div className="label">Image gen time</div>
          <div className="value">{fmtMs(img?.gen_p50_ms)}</div>
          <div className="sub">per frame, session-p50 median · p90 {fmtMs(img?.gen_p90_ms)}</div>
        </div>
        <div className="stat">
          <div className="label">Render ratio</div>
          <div className="value">{h100Ratio == null ? (imgRatio == null ? '—' : `${Math.round(imgRatio * 100)}%`) : `${Math.round(h100Ratio * 100)}%`}</div>
          <div className="sub">
            frames rendered / sketches sent{h100Ratio != null ? ' (H100 sessions)' : ''} — &lt;100% = stale
            sketches dropped under load (by design; falling = contention)
          </div>
        </div>
        <div className="stat">
          <div className="label">Video gen time</div>
          <div className="value">{fmtMs(vid?.gen_p50_ms)}</div>
          <div className="sub">per animation · p90 {fmtMs(vid?.gen_p90_ms)}</div>
        </div>
        <div className="stat">
          <div className="label">Stability</div>
          <div className="value">{(img?.downgraded ?? 0) + (img?.disconnected ?? 0)}</div>
          <div className="sub">
            {img?.downgraded ?? 0} downgraded to fal · {img?.disconnected ?? 0} sessions with drops · videos: {vid?.videos_cancelled ?? 0} cancelled (drew again) / {vid?.videos_failed ?? 0} failed
          </div>
        </div>
      </div>

      {/* ── 4: spend ── */}
      {(() => {
        const gpu = data.gpu_spend ?? [];
        const fal = data.fal_spend ?? [];
        const gpuTotal = gpu.reduce((a, r) => a + Number(r.cost_usd), 0);
        const falUser = Number(fal.find((r) => r.source === 'user')?.cost_usd ?? 0);
        const falWarmer = Number(fal.find((r) => r.source === 'warmer')?.cost_usd ?? 0);
        const total = gpuTotal + falUser + falWarmer;
        const stillOpen = gpu.reduce((a, r) => a + r.still_open, 0);
        const usd = (v: number): string => `$${v.toFixed(2)}`;
        return (
          <>
            <div className="section-title">Spend (7d)</div>
            <div className="stat-row">
              <div className="stat">
                <div className="label">Total infra spend</div>
                <div className="value">{usd(total)}</div>
                <div className="sub">GPU {usd(gpuTotal)} · fal {usd(falUser + falWarmer)}</div>
              </div>
              <div className="stat">
                <div className="label">GPU (Lambda instances)</div>
                <div className="value">{usd(gpuTotal)}</div>
                <div className="sub">
                  {gpu.reduce((a, r) => a + Number(r.gpu_hours), 0).toFixed(1)} instance-hrs
                  {stillOpen > 0 ? ` · ${stillOpen} still running (counting to now)` : ''}
                </div>
              </div>
              <div className="stat">
                <div className="label">fal — drawing</div>
                <div className="value">{usd(falUser)}</div>
                <div className="sub">the fallback path (attached time only)</div>
              </div>
              <div className="stat">
                <div className="label">fal — keep-warm</div>
                <div className="value">{usd(falWarmer)}</div>
                <div className="sub">warmer overhead (tune in Ops)</div>
              </div>
            </div>

            {gpu.length > 0 && (
              <div className="card" style={{ padding: 0 }}>
                <table>
                  <thead>
                    <tr>
                      <th>Pool</th><th>GPU type</th><th>$/hr</th><th>Instances</th>
                      <th>Instance-hrs</th><th>Cost</th>
                    </tr>
                  </thead>
                  <tbody>
                    {gpu.map((r, i) => (
                      <tr key={i}>
                        <td>{r.pool}</td>
                        <td><strong>{r.itype.replace('gpu_1x_', '') || '(unknown)'}</strong></td>
                        <td>${Number(r.price_hr).toFixed(2)}</td>
                        <td>{r.instances}{r.still_open > 0 ? ` (${r.still_open} open)` : ''}</td>
                        <td>{Number(r.gpu_hours).toFixed(1)}</td>
                        <td><strong>{usd(Number(r.cost_usd))}</strong></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
              GPU cost = reconstructed instance lifetime (launch → terminate, priced by type) — approximate:
              open instances count to now, and the launch→ready boot window (a few min) is included.
              fal bills warm-attached time only (cold spin-up is unbilled). Per-user metered spend (the
              free-tier ledger) is separate — this is what WE pay.
            </div>

            {/* daily spend trend */}
            {(data.spend_daily ?? []).length > 0 && (
              <div className="card" style={{ padding: 0, marginTop: 8 }}>
                <table>
                  <thead>
                    <tr><th>Day</th><th>GPU</th><th>fal</th><th>Total</th></tr>
                  </thead>
                  <tbody>
                    {data.spend_daily.map((d) => (
                      <tr key={d.day}>
                        <td>{d.day}</td>
                        <td>{usd(Number(d.gpu_usd))}</td>
                        <td>{usd(Number(d.fal_usd))}</td>
                        <td><strong>{usd(Number(d.gpu_usd) + Number(d.fal_usd))}</strong></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </>
        );
      })()}

      {/* ── 5: fleet lifecycle ── */}
      <div className="section-title">Fleet lifecycle (7d)</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Pool</th><th>Launches</th><th>Capacity granted</th><th>Became ready</th>
              <th>Search p50 / max</th><th>Boot p50 / max</th><th>Died</th><th>Stalled</th>
              <th>Idle-reaped</th><th>Drained</th>
            </tr>
          </thead>
          <tbody>
            {data.pools.map((p) => (
              <tr key={p.pool}>
                <td><strong>{p.pool}</strong></td>
                <td>{p.launch_requests}</td>
                <td>{p.capacity_granted}</td>
                <td>{p.became_ready}</td>
                <td>{fmtMs(p.search_p50_ms)} / {fmtMs(p.search_max_ms)}</td>
                <td>{fmtMs(p.boot_p50_ms)} / {fmtMs(p.boot_max_ms)}</td>
                <td>{p.died}</td>
                <td>{p.boot_stalled}</td>
                <td>{p.idle_reaped}</td>
                <td>{p.drained}</td>
              </tr>
            ))}
            {data.pools.length === 0 && (
              <tr><td colSpan={10} className="muted">No pool events in the last 7 days.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        Search = capacity request → granted (capacity-bound, unpredictable — max matters).
        Boot = granted → serving (consistent; the popover's progress bar uses its estimate).
        Drained = the Ops kill switch terminating instances.
      </div>

      {/* ── every GPU hunt, including the failures ── */}
      <div className="section-title">Every GPU hunt (7d) — step-by-step, failures included</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Requested</th><th>Pool</th><th>Capacity search</th><th>Boot</th><th>End</th>
            </tr>
          </thead>
          <tbody>
            {(data.acquisitions ?? []).map((a, i) => {
              const ageMs = Date.now() - new Date(a.ts).getTime();
              const searchLabel = a.search_outcome
                ? a.search_outcome
                : ageMs < 25 * 60_000 ? 'searching now…' : 'no terminal event (redeploy or pre-instrumentation)';
              const searchCls = a.search_outcome === 'launched' ? 'warm'
                : a.search_outcome ? 'fail'
                : ageMs < 25 * 60_000 ? 'cold' : 'fail';
              return (
                <tr key={i}>
                  <td style={{ whiteSpace: 'nowrap' }}>{new Date(a.ts).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</td>
                  <td>{a.pool}</td>
                  <td>
                    <span className={`pill ${searchCls}`}>{searchLabel}</span>
                    {a.search_ms != null && <strong style={{ marginLeft: 6 }}>{fmtMs(a.search_ms)}</strong>}
                    {a.search_detail && <div className="muted" style={{ fontSize: 11, maxWidth: 340, overflow: 'hidden', textOverflow: 'ellipsis' }}>{a.search_detail}</div>}
                  </td>
                  <td>
                    {a.search_outcome === 'launched' ? (
                      a.boot_outcome ? (
                        <>
                          <span className={`pill ${a.boot_outcome === 'ready' ? 'warm' : 'fail'}`}>{a.boot_outcome}</span>
                          {a.boot_ms != null && <strong style={{ marginLeft: 6 }}>{fmtMs(a.boot_ms)}</strong>}
                        </>
                      ) : (
                        <span className="pill cold">{ageMs < 25 * 60_000 ? 'booting…' : 'never became ready'}</span>
                      )
                    ) : <span className="muted">—</span>}
                  </td>
                  <td>
                    {a.end_event
                      ? <>
                          <span className="pill cold">{a.end_event.replace('_terminate', '-reap').replace('instance_dead', 'died')}</span>
                          {a.end_event === 'idle_terminate' && a.end_ms != null && <span className="muted" style={{ fontSize: 12, marginLeft: 6 }}>after {fmtMs(a.end_ms)} idle</span>}
                        </>
                      : a.search_outcome === 'launched' ? <span className="pill warm">still up</span> : <span className="muted">—</span>}
                  </td>
                </tr>
              );
            })}
            {(data.acquisitions ?? []).length === 0 && (
              <tr><td colSpan={5} className="muted">No capacity hunts in the last 7 days.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
        One row per capacity hunt. sweep_abandoned = the hunt stopped because demand went away (user left)
        — its duration is how long the user-facing "Finding a GPU…" lasted before they gave up.
        launch_failed = the retry window expired or a non-retryable API error. Terminal rows for
        abandoned/failed hunts ship with the 2026-07-25 backend; older losses show "no terminal event".
      </div>

      {/* ── raw event strip ── */}
      <div className="section-title">Recent fleet events</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr><th>When</th><th>Pool</th><th>Event</th><th>Instance</th><th>Duration</th><th>Detail</th></tr>
          </thead>
          <tbody>
            {data.recent_events.map((e, i) => (
              <tr key={i}>
                <td style={{ whiteSpace: 'nowrap' }}>{new Date(e.ts).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</td>
                <td>{e.pool}</td>
                <td><span className={`pill ${EVENT_CLS[e.event] ?? ''}`}>{e.event}</span></td>
                <td className="muted" style={{ fontSize: 12 }}>{e.instance_name?.replace(/^kiki-(serve|video)-/, '…') ?? ''}</td>
                <td>{fmtMs(e.duration_ms)}</td>
                <td className="muted" style={{ fontSize: 12, maxWidth: 320, overflow: 'hidden', textOverflow: 'ellipsis' }}>{e.detail ?? ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* ── 5: daily trend ── */}
      <div className="section-title">Daily trend (14d)</div>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Day</th><th>Sessions</th><th>On H100</th><th>Wait p50</th>
              <th>Render ratio</th><th>Animations</th>
            </tr>
          </thead>
          <tbody>
            {data.daily.map((d) => (
              <tr key={d.day}>
                <td>{d.day}</td>
                <td>{d.sessions}</td>
                <td>{pct(d.wired, d.sessions)}</td>
                <td>{fmtMs(d.wait_p50_ms)}</td>
                <td>{d.sketches ? `${Math.round((d.frames / d.sketches) * 100)}%` : '—'}</td>
                <td>{d.videos}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}


/** The live answer to "why is this pod up" — verdicts + interest straight
 * from the backend's pool memory (15s refresh). Empty pools still show
 * their interest trail, which is usually the interesting part. */
function LivePoolCards({ image, video }: { image?: LivePoolState; video?: LivePoolState }) {
  const fmtAge = (ms: number): string =>
    ms >= 3_600_000 ? `${(ms / 3_600_000).toFixed(1)}h` : ms >= 60_000 ? `${Math.round(ms / 60_000)}m` : `${Math.round(ms / 1000)}s`;
  const pool = (label: string, p?: LivePoolState) => (
    <div className="card" style={{ flex: 1, minWidth: 380 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 6 }}>
        <strong>{label}</strong>
        <span className={`pill ${p?.status === 'ready' ? 'warm' : p?.status === 'disabled' ? 'fail' : 'cold'}`}>
          {p?.status ?? '?'}{p?.enabled === false ? ' (flag off)' : ''}
        </span>
      </div>
      {(p?.instances ?? []).length === 0 && (
        <div className="muted" style={{ fontSize: 13 }}>No instances running.</div>
      )}
      {(p?.instances ?? []).map((i) => (
        <div key={i.name} style={{ padding: '6px 0', borderTop: '1px solid var(--border, #333)' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13 }}>
            <span className="monospace">{i.name.replace(/^kiki-(serve|video)-/, '…')} · {i.region}</span>
            <span className="muted">{i.status} · up {fmtAge(i.ageMs)} · {i.activeStreams} stream{i.activeStreams === 1 ? '' : 's'}</span>
          </div>
          <div style={{ fontSize: 13, marginTop: 2 }}>
            <strong>why up:</strong> {i.holdReason}
          </div>
        </div>
      ))}
      <div className="muted" style={{ fontSize: 12, marginTop: 8 }}>
        interest: {p?.interest?.lastSource
          ? `${p.interest.lastSource} (${p.interest.ageMs != null ? fmtAge(p.interest.ageMs) : '?'} ago)`
          : 'none recorded'}
        {(p?.interest?.recent ?? []).length > 1 && (
          <details style={{ marginTop: 2 }}>
            <summary style={{ cursor: 'pointer' }}>recent interest</summary>
            {(p?.interest?.recent ?? []).map((r, idx) => (
              <div key={idx} className="monospace" style={{ fontSize: 11 }}>
                {new Date(r.at).toLocaleTimeString()} — {r.source}
              </div>
            ))}
          </details>
        )}
      </div>
    </div>
  );
  return (
    <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
      {pool('Image pool', image)}
      {pool('Video pool', video)}
    </div>
  );
}
