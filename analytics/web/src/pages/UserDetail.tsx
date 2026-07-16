import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { CaptureGrid } from './Gallery';
import { ActivityChart } from '../ActivityBars';
import { getUser, type EventRow, type SessionRow, type UserDetail as Detail } from '../api';

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

// ─── Timeline grouped by app session ────────────────────────────────────────
// App sessions (source='app', rolled up on app.backgrounded) are the natural
// "visit" boundary. Everything else nests inside: drawing sessions and events
// whose timestamps fall within [start-SLACK, end+SLACK]. Events newer than the
// last CLOSED app session form the "current session" group (the roll-up only
// exists once the app backgrounds); anything else lands in honest "between
// sessions" buckets (webhooks, backend events while the app was closed).

/** Boundary slack: the events that DEFINE a session's edges (app.foregrounded /
 * backgrounded) carry the same timestamps as the rollup, and client/server
 * clocks can drift a little. */
const SLACK_MS = 90_000;

interface SessionGroup {
  key: string;
  kind: 'app' | 'open' | 'gap';
  start: number;
  durationMs: number | null;
  drawingSessions: SessionRow[];
  events: EventRow[];
}

function groupBySession(sessions: SessionRow[], events: EventRow[]): SessionGroup[] {
  const apps = sessions
    .filter((s) => s.source === 'app')
    .map((s) => {
      const start = new Date(s.started_at).getTime();
      const end = s.ended_at
        ? new Date(s.ended_at).getTime()
        : start + (s.duration_ms ?? 0);
      return { start, end, durationMs: s.duration_ms, key: `app-${s.id}` };
    })
    .sort((a, b) => b.start - a.start);

  const groups: SessionGroup[] = apps.map((a) => ({
    key: a.key,
    kind: 'app',
    start: a.start,
    durationMs: a.durationMs,
    drawingSessions: [],
    events: [],
  }));

  const findGroup = (t: number): SessionGroup | null => {
    for (let i = 0; i < apps.length; i++) {
      const a = apps[i];
      if (t >= a.start - SLACK_MS && t <= a.end + SLACK_MS) return groups[i];
    }
    return null;
  };

  const newestEnd = apps.length ? apps[0].end : -Infinity;
  let open: SessionGroup | null = null;
  const gaps = new Map<string, SessionGroup>();

  const place = (t: number, ev: EventRow | null, ds: SessionRow | null): void => {
    const g = findGroup(t);
    if (g) {
      if (ev) g.events.push(ev);
      if (ds) g.drawingSessions.push(ds);
      return;
    }
    if (t > newestEnd + SLACK_MS) {
      // Newer than the last closed app session → the not-yet-rolled-up visit.
      open ??= { key: 'open', kind: 'open', start: t, durationMs: null, drawingSessions: [], events: [] };
      open.start = Math.min(open.start, t);
      if (ev) open.events.push(ev);
      if (ds) open.drawingSessions.push(ds);
      return;
    }
    // Orphan between sessions — bucket per preceding app session so
    // consecutive orphans merge into one group.
    const after = apps.findIndex((a) => t > a.end);
    const key = `gap-${after}`;
    let g2 = gaps.get(key);
    if (!g2) {
      g2 = { key, kind: 'gap', start: t, durationMs: null, drawingSessions: [], events: [] };
      gaps.set(key, g2);
    }
    g2.start = Math.max(g2.start, t);
    if (ev) g2.events.push(ev);
    if (ds) g2.drawingSessions.push(ds);
  };

  for (const ev of events) place(new Date(ev.occurred_at).getTime(), ev, null);
  for (const ds of sessions.filter((s) => s.source === 'drawing')) {
    place(new Date(ds.started_at).getTime(), null, ds);
  }

  const all = [...groups, ...gaps.values()];
  if (open) all.push(open);
  // Drop empty gap groups only; keep empty app sessions (a visit with no
  // loaded events is still a visit — events beyond the 1000-row fetch window).
  const kept = all.filter((g) => g.kind !== 'gap' || g.events.length + g.drawingSessions.length > 0);
  kept.sort((a, b) => b.start - a.start);
  for (const g of kept) {
    g.events.sort((a, b) => new Date(a.occurred_at).getTime() - new Date(b.occurred_at).getTime());
    g.drawingSessions.sort((a, b) => new Date(a.started_at).getTime() - new Date(b.started_at).getTime());
  }
  return kept;
}

// ─── Color-coded JSON viewer (event properties) ─────────────────────────────
// Tiny recursive renderer — React spans, no innerHTML. Palette matches the
// site: keys accent-blue, strings green, numbers amber, booleans/null red.
const JC = { key: '#6ea8fe', str: '#7ee787', num: '#f0b429', lit: '#ff7b72', punc: '#9aa3b2' };

function Json({ v, ind = 0 }: { v: unknown; ind?: number }) {
  const pad = '  '.repeat(ind);
  const padIn = '  '.repeat(ind + 1);
  if (v === null || typeof v === 'boolean' || typeof v === 'undefined')
    return <span style={{ color: JC.lit }}>{String(v)}</span>;
  if (typeof v === 'number') return <span style={{ color: JC.num }}>{String(v)}</span>;
  if (typeof v === 'string') return <span style={{ color: JC.str }}>"{v}"</span>;
  if (Array.isArray(v)) {
    if (v.length === 0) return <span style={{ color: JC.punc }}>[]</span>;
    return (
      <span>
        <span style={{ color: JC.punc }}>{'[\n'}</span>
        {v.map((x, i) => (
          <span key={i}>
            {padIn}
            <Json v={x} ind={ind + 1} />
            {i < v.length - 1 ? ',' : ''}
            {'\n'}
          </span>
        ))}
        {pad}
        <span style={{ color: JC.punc }}>]</span>
      </span>
    );
  }
  const entries = Object.entries(v as Record<string, unknown>);
  if (entries.length === 0) return <span style={{ color: JC.punc }}>{'{}'}</span>;
  return (
    <span>
      <span style={{ color: JC.punc }}>{'{\n'}</span>
      {entries.map(([k, x], i) => (
        <span key={k}>
          {padIn}
          <span style={{ color: JC.key }}>"{k}"</span>
          <span style={{ color: JC.punc }}>: </span>
          <Json v={x} ind={ind + 1} />
          {i < entries.length - 1 ? ',' : ''}
          {'\n'}
        </span>
      ))}
      {pad}
      <span style={{ color: JC.punc }}>{'}'}</span>
    </span>
  );
}

const groupTitle = (g: SessionGroup): string => {
  const d = new Date(g.start);
  const day = d.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  if (g.kind === 'open') return `${day}, ${time} — current session (app not yet closed)`;
  if (g.kind === 'gap') return `${day}, ${time} — between sessions`;
  return `${day}, ${time} · ${dur(g.durationMs)}`;
};

export function UserDetail() {
  const { id } = useParams<{ id: string }>();
  const [data, setData] = useState<Detail | null>(null);
  const [error, setError] = useState('');
  const [filter, setFilter] = useState('');
  const [expanded, setExpanded] = useState<Set<number>>(new Set());

  const toggleExpanded = (id: number) =>
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  useEffect(() => {
    if (!id) return;
    getUser(id)
      .then(setData)
      .catch(() => setError('Failed to load user'));
  }, [id]);

  const groups = useMemo(() => {
    if (!data) return [];
    const all = groupBySession(data.sessions, data.events);
    const f = filter.trim().toLowerCase();
    if (!f) return all;
    // Filter events within groups; hide groups left with nothing to show.
    return all
      .map((g) => ({ ...g, events: g.events.filter((e) => e.name.toLowerCase().includes(f)) }))
      .filter((g) => g.events.length > 0);
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
      <div className="section-title">Activity by day</div>
      <ActivityChart data={data.daily_activity ?? []} />

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

      {/* Timeline grouped by app session (open→close), newest first */}
      <div className="section-title">Timeline by session ({groups.filter((g) => g.kind === 'app').length} app sessions)</div>
      <div className="filter-bar">
        <input
          placeholder="Filter events by name…"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          style={{ flex: 1 }}
        />
      </div>
      {groups.length === 0 && <div className="muted">No sessions or events recorded yet.</div>}
      {groups.map((g, i) => (
        // key includes the filter so toggling a filter re-applies the default
        // open state (native <details> keeps its own state otherwise).
        <details
          key={`${g.key}-${filter ? 'f' : 'n'}`}
          className={`session-group ${g.kind}`}
          open={!!filter || i < 3}
        >
          <summary>
            <span className={`pill ${g.kind === 'app' ? 'src-user' : ''}`}>
              {g.kind === 'gap' ? 'between' : g.kind === 'open' ? 'live' : 'session'}
            </span>{' '}
            <strong>{groupTitle(g)}</strong>
            <span className="muted" style={{ marginLeft: 10 }}>
              {g.drawingSessions.length > 0 && <>{g.drawingSessions.length} drawing{g.drawingSessions.length > 1 ? 's' : ''} · </>}
              {g.events.length} events
            </span>
          </summary>
          <div className="session-group-body">
            {g.drawingSessions.map((s) => (
              <div key={s.id} className="event-row">
                <span className="ts">{new Date(s.started_at).toLocaleTimeString()}</span>
                <span className="name">
                  <span className="pill drawing">drawing</span>
                </span>
                <span className="props mono">
                  {dur(s.duration_ms)}
                  {s.drawing_id ? ` · ${s.drawing_id.slice(0, 8)}` : ''}
                </span>
              </div>
            ))}
            {g.events.map((e) => {
              const hasProps = Object.keys(e.properties).length > 0;
              const isOpen = expanded.has(e.id);
              return (
                <div key={e.id}>
                  <div
                    className={`event-row${hasProps ? ' expandable' : ''}`}
                    title={hasProps ? 'Click to expand properties' : undefined}
                    onClick={hasProps ? () => toggleExpanded(e.id) : undefined}
                  >
                    <span className="ts">{new Date(e.occurred_at).toLocaleTimeString()}</span>
                    <span className="name">{e.name}</span>
                    <span className="props mono">
                      {hasProps && (
                        <span className="muted" style={{ marginRight: 6 }}>{isOpen ? '▾' : '▸'}</span>
                      )}
                      {hasProps && !isOpen ? JSON.stringify(e.properties) : ''}
                    </span>
                  </div>
                  {isOpen && (
                    <pre className="json-view">
                      <Json v={e.properties} />
                    </pre>
                  )}
                </div>
              );
            })}
            {g.events.length === 0 && g.drawingSessions.length === 0 && (
              <div className="muted" style={{ padding: '6px 0' }}>
                No events loaded for this session (beyond the most recent 1000).
              </div>
            )}
          </div>
        </details>
      ))}
    </div>
  );
}
