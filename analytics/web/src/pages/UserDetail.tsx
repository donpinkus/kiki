import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { CaptureGrid } from './Gallery';
import { getUser, type UserDetail as Detail } from '../api';

const fmt = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : '—');

function dur(ms: number | null): string {
  if (ms == null) return '—';
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  if (m < 60) return `${m}m ${rem}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

export function UserDetail() {
  const { id } = useParams<{ id: string }>();
  const [data, setData] = useState<Detail | null>(null);
  const [error, setError] = useState('');
  const [filter, setFilter] = useState('');

  useEffect(() => {
    if (!id) return;
    getUser(id)
      .then(setData)
      .catch(() => setError('Failed to load user'));
  }, [id]);

  const filteredEvents = useMemo(() => {
    if (!data) return [];
    const f = filter.trim().toLowerCase();
    return f ? data.events.filter((e) => e.name.toLowerCase().includes(f)) : data.events;
  }, [data, filter]);

  if (error) return <div className="container error">{error}</div>;
  if (!data) return <div className="container muted">Loading…</div>;

  const { user, sessions, drawings, usage } = data;
  const lastActive = data.events[0]?.occurred_at ?? null;

  return (
    <div className="container">
      <Link to="/" className="muted">← All users</Link>

      <div className="card" style={{ marginTop: 12 }}>
        <h2 style={{ margin: '0 0 8px' }}>
          {user.email || 'Anonymous'}
          {user.is_test_account && <span className="pill app" style={{ marginLeft: 10 }}>test account</span>}
          <span className="pill" style={{ marginLeft: 8 }}>sub: {user.subscription_status}</span>
        </h2>
        <div className="mono muted">{user.user_id}</div>
        <div className="muted" style={{ marginTop: 10 }}>
          Account created {fmt(user.created_at)} · Last active {fmt(lastActive)} ·{' '}
          {sessions.length} sessions · {drawings.length} drawings · {data.events.length} events
        </div>
        {usage.length > 0 && (
          <div style={{ marginTop: 12 }}>
            <span className="muted">Fal spend: </span>
            {usage.map((m) => (
              <span key={m.month} className="pill" style={{ marginRight: 6 }}>
                {m.month} ${m.fal_spend_usd.toFixed(2)}
              </span>
            ))}
          </div>
        )}
      </div>

      {/* Session / login timeline */}
      <div className="section-title">Login & session timeline</div>
      {sessions.length === 0 ? (
        <div className="muted">No sessions recorded yet.</div>
      ) : (
        <div className="timeline">
          {sessions.map((s) => (
            <div key={s.id} className={`timeline-item ${s.source}`}>
              <div>
                <span className={`pill ${s.source}`}>{s.source}</span>{' '}
                <strong>{fmt(s.started_at)}</strong>
              </div>
              <div className="muted">
                Duration {dur(s.duration_ms)}
                {s.drawing_id && <> · drawing <span className="mono">{s.drawing_id.slice(0, 8)}</span></>}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Session replays (captured sketch/generated frame streams) */}
      <div className="section-title">Session replays</div>
      <CaptureGrid userId={id} />

      {/* Drawings gallery */}
      <div className="section-title">Drawings ({drawings.length})</div>
      {drawings.length === 0 ? (
        <div className="muted">No drawings uploaded yet.</div>
      ) : (
        <div className="gallery">
          {drawings.map((d) => (
            <div key={d.drawing_id} className="draw-card">
              <div className="imgs">
                <img src={d.thumbnail_url ?? ''} alt="canvas" loading="lazy" />
                <img src={d.generated_url ?? ''} alt="generated" loading="lazy" />
              </div>
              <div className="meta">
                <p className="prompt">{d.prompt || <span className="muted">no prompt</span>}</p>
                <div className="muted mono">{d.style_id || '—'}</div>
                <div className="muted">{fmt(d.updated_at)}</div>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Event stream */}
      <div className="section-title">Event stream</div>
      <div className="filter-bar">
        <input
          placeholder="Filter events by name…"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          style={{ flex: 1 }}
        />
      </div>
      <div className="events card">
        <div
          className="event-row"
          style={{ color: 'var(--muted)', textTransform: 'uppercase', fontSize: 12, letterSpacing: '.04em', fontWeight: 600 }}
        >
          <span>Time</span>
          <span>Event</span>
          <span>Properties</span>
        </div>
        {filteredEvents.map((e) => (
          <div key={e.id} className="event-row">
            <span className="ts">{new Date(e.occurred_at).toLocaleTimeString()}</span>
            <span className="name">{e.name}</span>
            <span className="props mono" title={JSON.stringify(e.properties)}>
              {Object.keys(e.properties).length ? JSON.stringify(e.properties) : ''}
            </span>
          </div>
        ))}
        {filteredEvents.length === 0 && <div className="muted">No matching events.</div>}
      </div>
    </div>
  );
}
