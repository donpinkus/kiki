import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { listCaptures, type CaptureStreamSummary } from '../api';

const fmtAgo = (iso: string) => {
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 48 * 3600) return `${Math.round(s / 3600)}h ago`;
  return new Date(iso).toLocaleString();
};

const fmtDuration = (a: string, b: string) => {
  const s = Math.max(0, Math.round((new Date(b).getTime() - new Date(a).getTime()) / 1000));
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
};

/** Grid of captured drawing sessions (newest first). Reused by the Gallery
 * page (all users) and UserDetail's replay section (one user). */
export function CaptureGrid({ userId }: { userId?: string }) {
  const [captures, setCaptures] = useState<CaptureStreamSummary[] | null>(null);

  useEffect(() => {
    listCaptures(userId).then((r) => setCaptures(r.captures));
  }, [userId]);

  if (!captures) return <div className="muted">Loading…</div>;
  if (captures.length === 0)
    return (
      <div className="muted">
        No session replays yet — they record automatically while users draw.
      </div>
    );

  return (
    <div className="gallery">
      {captures.map((c) => (
        <Link key={c.stream_id} to={`/gallery/${c.stream_id}`} style={{ color: 'inherit' }}>
          <div className="draw-card">
            {c.poster_url ? (
              <img
                src={c.poster_url}
                alt="last generated frame"
                style={{ width: '100%', aspectRatio: '1', objectFit: 'cover', background: '#000', display: 'block' }}
              />
            ) : (
              <div
                className="muted"
                style={{ aspectRatio: '1', display: 'flex', alignItems: 'center', justifyContent: 'center' }}
              >
                no generated frames
              </div>
            )}
            <div className="meta">
              <p className="prompt">{c.email ?? <span className="mono">{c.user_id.slice(0, 8)}</span>}</p>
              {c.last_prompt && (
                <div
                  className="muted"
                  style={{ fontSize: 12, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}
                  title={c.last_prompt}
                >
                  “{c.last_prompt}”
                </div>
              )}
              <div className="muted" style={{ fontSize: 12 }}>
                {fmtAgo(c.ended_at)} · {fmtDuration(c.started_at, c.ended_at)} ·{' '}
                {c.generated_count} frames
              </div>
            </div>
          </div>
        </Link>
      ))}
    </div>
  );
}

export function Gallery() {
  return (
    <div className="container">
      <div className="section-title">Session replays — all users</div>
      <CaptureGrid />
    </div>
  );
}
