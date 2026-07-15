import { useState } from 'react';

/** Bar hue validated against the dark panel surface (#181b22) — dataviz
 * lightness band + contrast pass. Zero-day stubs use the border gray. */
const BAR = '#5b93ea';
const BAR_HOVER = '#8ab4f4';
const STUB = '#2a2f3a';

const fmtDay = (d: Date, withYear: boolean) =>
  d.toLocaleDateString([], {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    ...(withYear ? { year: 'numeric' } : {}),
  });

interface Tip {
  x: number;
  text: string;
}

/** Immediate hover tooltip + full-height hit targets over an SVG bar row.
 * Native <title> tooltips are too slow/subtle for a data readout. */
function BarTooltip({ tip }: { tip: Tip | null }) {
  if (!tip) return null;
  return (
    <div
      style={{
        position: 'absolute',
        left: tip.x,
        top: -4,
        transform: 'translate(-50%, -100%)',
        background: 'var(--panel-2)',
        border: '1px solid var(--border)',
        borderRadius: 6,
        padding: '4px 8px',
        fontSize: 12,
        whiteSpace: 'nowrap',
        pointerEvents: 'none',
        zIndex: 10,
        boxShadow: '0 4px 12px rgba(0,0,0,.45)',
      }}
    >
      {tip.text}
    </div>
  );
}

/** Row sparkline: last 14 Pacific days of in-app minutes. Full bar = ≥15 min;
 * 2px stub = 0. Hover any day for the exact date + minutes. */
export function Spark14({ data }: { data: number[] }) {
  const W = 6;
  const GAP = 2;
  const H = 22;
  const CAP = 15;
  const [hover, setHover] = useState<number | null>(null);
  const today = new Date();

  const dayOf = (i: number) => new Date(today.getTime() - (data.length - 1 - i) * 86_400_000);
  const tip: Tip | null =
    hover === null
      ? null
      : { x: hover * (W + GAP) + W / 2, text: `${fmtDay(dayOf(hover), false)} · ${data[hover]} min` };

  return (
    <div style={{ position: 'relative', display: 'inline-block', overflow: 'visible' }}>
      <BarTooltip tip={tip} />
      <svg
        width={data.length * (W + GAP) - GAP}
        height={H}
        role="img"
        aria-label="in-app minutes per day, last 14 days (full bar = 15+ min)"
        onMouseLeave={() => setHover(null)}
      >
        {data.map((m, i) => {
          const h = m <= 0 ? 2 : Math.max(3, Math.round((Math.min(m, CAP) / CAP) * H));
          return (
            <rect
              key={i}
              x={i * (W + GAP)}
              y={H - h}
              width={W}
              height={h}
              rx={1.5}
              fill={m <= 0 ? STUB : hover === i ? BAR_HOVER : BAR}
            />
          );
        })}
        {/* Full-height invisible hit targets — hovering a 2px stub is impossible otherwise. */}
        {data.map((_, i) => (
          <rect
            key={`hit-${i}`}
            x={i * (W + GAP) - GAP / 2}
            y={0}
            width={W + GAP}
            height={H}
            fill="transparent"
            onMouseEnter={() => setHover(i)}
          />
        ))}
      </svg>
    </div>
  );
}

/** Fill the day range from the first active day through today with zeros. */
function fillDays(data: { day: string; minutes: number }[]): { day: string; minutes: number }[] {
  if (data.length === 0) return [];
  const byDay = new Map(data.map((d) => [d.day, d.minutes]));
  const todayIso = new Date().toLocaleDateString('en-CA');
  const out: { day: string; minutes: number }[] = [];
  // Noon-UTC stepping keeps the date stable across DST transitions.
  for (
    let t = new Date(`${data[0].day}T12:00:00Z`).getTime();
    out.length < 1000;
    t += 86_400_000
  ) {
    const day = new Date(t).toISOString().slice(0, 10);
    out.push({ day, minutes: byDay.get(day) ?? 0 });
    if (day >= todayIso) break;
  }
  return out;
}

/** Full-history daily activity bars with a y-scale toggle: capped at 10 min
 * (per-day habit view) vs the user's true max (magnitude view). */
export function ActivityChart({ data }: { data: { day: string; minutes: number }[] }) {
  const [capped, setCapped] = useState(true);
  const [hover, setHover] = useState<number | null>(null);
  const days = fillDays(data);
  if (days.length === 0) return <div className="muted">No app sessions yet.</div>;

  const trueMax = Math.max(...days.map((d) => d.minutes), 1);
  const scaleMax = capped ? 10 : trueMax;
  const W = 6;
  const GAP = 2;
  const PLOT_H = 96;
  const LABEL_H = 16;
  const width = days.length * (W + GAP) - GAP;

  // Sparse x labels: first bar + every month boundary.
  const labels = days
    .map((d, i) => ({ ...d, i }))
    .filter(({ day, i }) => i === 0 || day.endsWith('-01'));

  const tip: Tip | null =
    hover === null
      ? null
      : {
          x: hover * (W + GAP) + W / 2,
          text: `${fmtDay(new Date(`${days[hover].day}T12:00:00`), true)} · ${days[hover].minutes} min`,
        };

  return (
    <div className="card" style={{ padding: 16 }}>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 10 }}>
        <span className="muted" style={{ fontSize: 12, flex: 1 }}>
          In-app minutes per day (Pacific) — scale 0–{scaleMax}m
          {capped && trueMax > 10 ? ', bars cap at 10m' : ''}
        </span>
        {([true, false] as const).map((c) => (
          <button
            key={String(c)}
            className="ghost"
            onClick={() => setCapped(c)}
            style={{ padding: '2px 10px', fontSize: 12, opacity: capped === c ? 1 : 0.5 }}
          >
            {c ? 'Cap 10 min' : `True max (${trueMax}m)`}
          </button>
        ))}
      </div>
      <div style={{ overflowX: 'auto', overflowY: 'visible', paddingTop: 34 }}>
        <div style={{ position: 'relative', width }}>
          <BarTooltip tip={tip} />
          <svg
            width={width}
            height={PLOT_H + LABEL_H}
            role="img"
            aria-label="in-app minutes per day since first session"
            onMouseLeave={() => setHover(null)}
          >
            {days.map((d, i) => {
              const h =
                d.minutes <= 0
                  ? 2
                  : Math.max(3, Math.round((Math.min(d.minutes, scaleMax) / scaleMax) * PLOT_H));
              return (
                <rect
                  key={d.day}
                  x={i * (W + GAP)}
                  y={PLOT_H - h}
                  width={W}
                  height={h}
                  rx={1.5}
                  fill={d.minutes <= 0 ? STUB : hover === i ? BAR_HOVER : BAR}
                />
              );
            })}
            {labels.map(({ day, i }) => (
              <text key={day} x={i * (W + GAP)} y={PLOT_H + 12} fill="#9aa3b2" fontSize={10}>
                {new Date(`${day}T12:00:00`).toLocaleDateString([], { month: 'short', day: 'numeric' })}
              </text>
            ))}
            {days.map((_, i) => (
              <rect
                key={`hit-${i}`}
                x={i * (W + GAP) - GAP / 2}
                y={0}
                width={W + GAP}
                height={PLOT_H}
                fill="transparent"
                onMouseEnter={() => setHover(i)}
              />
            ))}
          </svg>
        </div>
      </div>
    </div>
  );
}
