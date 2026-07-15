import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { getCapture, type CaptureDetail, type CaptureFrame } from '../api';

const SPEEDS = [1, 2, 4, 8];

const fmtClock = (ms: number) => {
  const s = Math.floor(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};

/** Latest frame of `frames` (ascending by time) at or before `t` ms-from-start. */
function frameAt(frames: { t: number; url: string }[], t: number): string | null {
  let found: string | null = null;
  for (const f of frames) {
    if (f.t > t) break;
    found = f.url;
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
    const sketches = detail.frames.filter((f) => f.kind === 'sketch').map(rel);
    const generated = detail.frames.filter((f) => f.kind === 'generated').map(rel);
    const duration = Math.max(
      sketches[sketches.length - 1]?.t ?? 0,
      generated[generated.length - 1]?.t ?? 0,
      1,
    );
    return { sketches, generated, duration };
  }, [detail]);

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

  const sketchUrl = frameAt(timeline.sketches, playhead);
  const generatedUrl = frameAt(timeline.generated, playhead);
  const atEnd = playhead >= timeline.duration;

  return (
    <div className="container">
      <div className="section-title">
        <Link to="/gallery">← Gallery</Link> — replay ·{' '}
        {detail.email ?? <span className="mono">{detail.user_id?.slice(0, 8)}</span>} ·{' '}
        {new Date(detail.frames[0].captured_at).toLocaleString()}
      </div>

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
        <input
          type="range"
          min={0}
          max={timeline.duration}
          value={playhead}
          onChange={(e) => setPlayhead(Number(e.target.value))}
          style={{ flex: 1, minWidth: 200 }}
        />
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
      </div>
    </div>
  );
}
