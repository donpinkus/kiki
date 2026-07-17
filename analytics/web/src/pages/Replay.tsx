import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { getCapture, type CaptureDetail, type CaptureFrame } from '../api';

const SPEEDS = [1, 2, 4, 8];

const fmtClock = (ms: number) => {
  const s = Math.floor(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

/** Latest item of `items` (ascending by .t) at or before `t` ms-from-start. */
function lastAt<T extends { t: number }>(items: T[], t: number): T | null {
  let found: T | null = null;
  for (const f of items) {
    if (f.t > t) break;
    found = f;
  }
  return found;
}

/** Side-by-side sketch/generated replay of one captured drawing session.
 * Plays wall-clock time (scaled by speed), so pauses in the user's drawing
 * appear as pauses in the replay — scrub past them with the slider. */
export function Replay() {
  const { streamId } = useParams<{ streamId: string }>();
  const [detail, setDetail] = useState<CaptureDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [playhead, setPlayhead] = useState(0);
  const [playing, setPlaying] = useState(true);
  const [speed, setSpeed] = useState(4);
  // 'stitch' (default): frames play as a uniform flipbook — one captured
  // event per tick, idle time gone entirely. 'real': faithful wall-clock
  // playback from the timestamps (pauses and generation latency preserved).
  const [mode, setMode] = useState<'stitch' | 'real'>('stitch');
  const lastTickRef = useRef<number | null>(null);

  useEffect(() => {
    if (!streamId) return;
    getCapture(streamId)
      .then((d) => {
        setDetail(d);
        // Preload every frame so playback never flashes a half-loaded image.
        for (const f of d.frames) new Image().src = f.url;
      })
      .catch((e) => setError(String(e)));
  }, [streamId]);

  const timeline = useMemo(() => {
    if (!detail || detail.frames.length === 0) return null;
    const t0 = new Date(detail.frames[0].captured_at).getTime();
    const rel = (f: CaptureFrame) => ({ t: new Date(f.captured_at).getTime() - t0, url: f.url });
    let sketches = detail.frames.filter((f) => f.kind === 'sketch').map(rel);
    let generated = detail.frames.filter((f) => f.kind === 'generated').map(rel);
    // Prompts before the first frame (the session-open config) clamp to t=0 —
    // no dead intro while the user hadn't drawn yet.
    let prompts = (detail.prompts ?? []).map((p) => ({
      t: Math.max(0, new Date(p.captured_at).getTime() - t0),
      prompt: p.prompt,
    }));

    if (mode === 'stitch') {
      // Skip-idle flipbook: merge every captured event (both frame kinds +
      // prompt changes) into one sequence ordered by real time, then respace
      // uniformly — one event per STEP. Real timestamps only decide ORDER, so
      // prompts still flip at the right moment relative to the frames, but
      // idle gaps contribute nothing to playback time.
      const STEP = 1000; // per event at 1× — the default 4× ≈ 4 events/s
      type Ev =
        | { kind: 'sketch' | 'generated'; t: number; url: string }
        | { kind: 'prompt'; t: number; prompt: string };
      const events: Ev[] = [
        ...sketches.map((s) => ({ kind: 'sketch' as const, ...s })),
        ...generated.map((g) => ({ kind: 'generated' as const, ...g })),
        ...prompts.map((p) => ({ kind: 'prompt' as const, ...p })),
      ].sort((a, b) => a.t - b.t);
      const stitched = events.map((e, i) => ({ ...e, t: i * STEP }));
      sketches = stitched.filter((e) => e.kind === 'sketch') as typeof sketches;
      generated = stitched.filter((e) => e.kind === 'generated') as typeof generated;
      prompts = stitched.filter((e) => e.kind === 'prompt') as typeof prompts;
      return { sketches, generated, prompts, duration: events.length * STEP };
    }

    const duration = Math.max(
      sketches[sketches.length - 1]?.t ?? 0,
      generated[generated.length - 1]?.t ?? 0,
      prompts[prompts.length - 1]?.t ?? 0,
      1,
    );
    return { sketches, generated, prompts, duration };
  }, [detail, mode]);

  // Mode switch rebuilds the timeline with different timebases — restart.
  useEffect(() => {
    setPlayhead(0);
  }, [mode]);

  useEffect(() => {
    if (!playing || !timeline) return;
    const id = setInterval(() => {
      const now = performance.now();
      const dt = lastTickRef.current === null ? 0 : now - lastTickRef.current;
      lastTickRef.current = now;
      setPlayhead((p) => {
        const next = p + dt * speed;
        if (next >= timeline.duration) {
          setPlaying(false);
          return timeline.duration;
        }
        return next;
      });
    }, 66);
    return () => {
      clearInterval(id);
      lastTickRef.current = null;
    };
  }, [playing, speed, timeline]);

  if (error) return <div className="container" style={{ color: '#ff7b72' }}>{error}</div>;
  if (!detail || !timeline) return <div className="container muted">Loading…</div>;

  const sketchUrl = lastAt(timeline.sketches, playhead)?.url ?? null;
  const generatedUrl = lastAt(timeline.generated, playhead)?.url ?? null;
  const currentPrompt = lastAt(timeline.prompts, playhead);
  const atEnd = playhead >= timeline.duration;

  return (
    <div className="container">
      <div className="section-title">
        <Link to="/gallery">← Gallery</Link> — replay ·{' '}
        {detail.email ?? <span className="mono">{detail.user_id?.slice(0, 8)}</span>} ·{' '}
        {new Date(detail.frames[0].captured_at).toLocaleString()}
      </div>

      {currentPrompt && (
        // key remount on each prompt change → the flash animation replays,
        // making mid-drawing prompt edits pop during playback.
        <div key={currentPrompt.t} className="card prompt-flash" style={{ marginBottom: 16, padding: '10px 14px', fontSize: 13 }}>
          <span
            className="muted"
            style={{ fontSize: 11, textTransform: 'uppercase', letterSpacing: '.04em', marginRight: 10 }}
          >
            Prompt
          </span>
          “{currentPrompt.prompt}”
        </div>
      )}

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap' }}>
        {(
          [
            ['Sketch', sketchUrl, timeline.sketches.length],
            ['Generated', generatedUrl, timeline.generated.length],
          ] as const
        ).map(([label, url, count]) => (
          <div key={label} className="card" style={{ flex: 1, minWidth: 320, padding: 12 }}>
            <div className="muted" style={{ fontSize: 12, marginBottom: 8 }}>
              {label} ({count} frames)
            </div>
            {url ? (
              <img src={url} alt={label} style={{ width: '100%', aspectRatio: '1', objectFit: 'contain', background: '#000', borderRadius: 6 }} />
            ) : (
              <div className="muted" style={{ aspectRatio: '1', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                nothing yet
              </div>
            )}
          </div>
        ))}
      </div>

      <div className="card" style={{ marginTop: 16, display: 'flex', gap: 14, alignItems: 'center', flexWrap: 'wrap' }}>
        <button
          onClick={() => {
            if (atEnd) setPlayhead(0);
            setPlaying(!playing || atEnd);
          }}
          style={{ width: 90 }}
        >
          {playing ? 'Pause' : atEnd ? 'Replay' : 'Play'}
        </button>
        <div style={{ flex: 1, minWidth: 200, position: 'relative' }}>
          <input
            type="range"
            min={0}
            max={timeline.duration}
            value={playhead}
            onChange={(e) => setPlayhead(Number(e.target.value))}
            style={{ width: '100%', display: 'block' }}
          />
          {/* Amber diamonds mark mid-session prompt changes (first prompt is
              the baseline, not a change). Hover shows the new text. */}
          {timeline.prompts.slice(1).map((p) => (
            <div
              key={p.t}
              title={p.prompt}
              style={{
                position: 'absolute',
                left: `${(p.t / timeline.duration) * 100}%`,
                top: -5,
                width: 7,
                height: 7,
                background: '#f0b429',
                transform: 'translateX(-50%) rotate(45deg)',
                borderRadius: 1,
              }}
            />
          ))}
        </div>
        <span className="mono muted" style={{ minWidth: 90 }}>
          {fmtClock(playhead)} / {fmtClock(timeline.duration)}
        </span>
        {SPEEDS.map((s) => (
          <button
            key={s}
            className="ghost"
            onClick={() => setSpeed(s)}
            style={{ padding: '2px 10px', opacity: speed === s ? 1 : 0.5 }}
          >
            {s}×
          </button>
        ))}
        <span style={{ width: 1, height: 18, background: 'var(--border)' }} />
        <label
          title="On: uniform flipbook — one captured frame per tick, idle time removed. Off: real-time playback from timestamps — pauses and generation latency preserved."
          style={{ display: 'flex', gap: 6, alignItems: 'center', fontSize: 13, cursor: 'pointer' }}
        >
          <input
            type="checkbox"
            checked={mode === 'stitch'}
            onChange={(e) => setMode(e.target.checked ? 'stitch' : 'real')}
          />
          Skip idle
        </label>
      </div>
    </div>
  );
}
