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
  /** px offset (SVG charts) or a CSS length like '42%' (flex-bar charts). */
  x: number | string;
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

/** Generic last-N-days bar chart (Launch tab): auto-scaled to the series max,
 * hover tooltip with date + formatted value, sparse month-boundary labels.
 * `byDay` is a sparse YYYY-MM-DD → value map; missing days render as stubs. */
export function DailyBars({
  byDay,
  days = 30,
  color = BAR,
  title,
  fmtValue = (v: number) => String(v),
}: {
  byDay: Record<string, number | null | undefined>;
  days?: number;
  color?: string;
  title: string;
  fmtValue?: (v: number) => string;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const W = 6;
  const GAP = 2;
  const H = 64;
  const list = Array.from({ length: days }, (_, i) => {
    const d = new Date(Date.now() - (days - 1 - i) * 86_400_000);
    const key = d.toLocaleDateString('en-CA');
    return { key, d, v: byDay[key] ?? null };
  });
  const max = Math.max(1, ...list.map((x) => x.v ?? 0));
  const tip: Tip | null =
    hover === null
      ? null
      : {
          x: hover * (W + GAP) + W / 2,
          text: `${list[hover].d.toLocaleDateString([], { month: 'short', day: 'numeric' })} · ${
            list[hover].v === null ? 'no data' : fmtValue(list[hover].v as number)
          }`,
        };

  return (
    <div className="card" style={{ padding: '12px 16px' }}>
      <div className="muted" style={{ fontSize: 12, marginBottom: 8, display: 'flex', justifyContent: 'space-between' }}>
        <span>{title}</span>
        <span>max {fmtValue(max)}</span>
      </div>
      <div style={{ position: 'relative', paddingTop: 26 }}>
        <BarTooltip tip={tip} />
        <svg
          width={list.length * (W + GAP) - GAP}
          height={H}
          role="img"
          aria-label={`${title}, last ${days} days`}
          onMouseLeave={() => setHover(null)}
        >
          {list.map((x, i) => {
            const v = x.v ?? 0;
            const h = v <= 0 ? 2 : Math.max(3, Math.round((v / max) * H));
            return (
              <rect
                key={x.key}
                x={i * (W + GAP)}
                y={H - h}
                width={W}
                height={h}
                rx={1.5}
                fill={v <= 0 ? STUB : hover === i ? BAR_HOVER : color}
              />
            );
          })}
          {list.map((_, i) => (
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
    </div>
  );
}

/** Cold-rate histogram for the Ops request history: one bar per time bucket,
 * height = % of RESOLVED connections in that bucket that found the fal pool
 * cold. Fixed 0–100% y-scale (a rate chart that rescales to its own max lies
 * about severity). Bar opacity encodes bucket volume so a lone 1-of-1 cold
 * bucket doesn't read as loud as a 40-of-80 one.
 *
 * Buckets come from a server-side aggregate over the whole range, NOT from the
 * table's 500-row page — so 7d/30d views are complete.
 *
 * Flex divs rather than the SVG idiom above because this chart spans the card
 * width (unknown at render time); an SVG would need a viewBox stretch that
 * distorts the axis labels. */
export function ColdRateBars({
  buckets,
  rangeSeconds,
  bucketSeconds,
}: {
  buckets: { bucket: string; total: number; resolved: number; cold: number }[];
  rangeSeconds: number;
  bucketSeconds: number;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const H = 84;
  const COLD = '#f0b429'; // matches .pill.cold in styles.css

  // Server emits only non-empty buckets; rebuild the full axis so gaps read as
  // gaps. Floor to the same epoch grid the server used, else bars misalign.
  const nowSec = Math.floor(Date.now() / 1000);
  const lastStart = Math.floor(nowSec / bucketSeconds) * bucketSeconds;
  const count = Math.max(1, Math.round(rangeSeconds / bucketSeconds));
  const byStart = new Map(
    buckets.map((b) => [Math.floor(new Date(b.bucket).getTime() / 1000), b]),
  );
  const slots = Array.from({ length: count }, (_, i) => {
    const start = lastStart - (count - 1 - i) * bucketSeconds;
    const b = byStart.get(start);
    return {
      start,
      date: new Date(start * 1000),
      total: b?.total ?? 0,
      resolved: b?.resolved ?? 0,
      cold: b?.cold ?? 0,
    };
  });

  const maxTotal = Math.max(1, ...slots.map((s) => s.total));
  const sumCold = slots.reduce((a, s) => a + s.cold, 0);
  const sumResolved = slots.reduce((a, s) => a + s.resolved, 0);
  const overall = sumResolved > 0 ? Math.round((sumCold / sumResolved) * 100) : null;

  const multiDay = rangeSeconds > 26 * 3600;
  const fmtBucket = (d: Date) =>
    bucketSeconds >= 86_400
      ? d.toLocaleDateString([], { month: 'short', day: 'numeric' })
      : multiDay
        ? d.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric' })
        : d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  // Midnight rules (local): a vertical line + date label at every day start, so
  // "which day is this spike on" is answerable without hovering. Only for
  // sub-day buckets — at ≥1d/bar every bar IS a day and the axis already says
  // so. Thinned past 10 boundaries (30d) or the lines become the chart.
  const dayStarts = (() => {
    if (bucketSeconds >= 86_400) return [] as { i: number; date: Date }[];
    const all = slots
      .map((s, i) => ({ i, date: s.date }))
      .filter(({ i }) => i > 0 && slots[i].date.getDate() !== slots[i - 1].date.getDate());
    const keep = Math.max(1, Math.ceil(all.length / 8));
    return all.length > 10 ? all.filter((_, n) => n % keep === 0) : all;
  })();

  // With day markers carrying the date, the axis only needs the time — a 48h
  // axis of "Aug 5, 8 AM / Aug 5, 4 PM" repeats the date six times.
  const fmtAxis = (d: Date) =>
    bucketSeconds >= 86_400
      ? d.toLocaleDateString([], { month: 'short', day: 'numeric' })
      : multiDay && dayStarts.length > 0
        ? d.toLocaleTimeString([], { hour: 'numeric' })
        : d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

  const pctOf = (s: (typeof slots)[number]) =>
    s.resolved > 0 ? (s.cold / s.resolved) * 100 : null;

  const bucketLabel =
    bucketSeconds >= 86_400
      ? `${Math.round(bucketSeconds / 86_400)}d`
      : bucketSeconds >= 3600
        ? `${Math.round(bucketSeconds / 3600)}h`
        : `${Math.round(bucketSeconds / 60)}m`;

  const h = hover === null ? null : slots[hover];
  const tip: Tip | null =
    h === null
      ? null
      : {
          x: `${((hover! + 0.5) / count) * 100}%`,
          text:
            h.resolved === 0
              ? `${fmtBucket(h.date)} · ${h.total === 0 ? 'no connections' : `${h.total} conn, no verdict`}`
              : `${fmtBucket(h.date)} · ${Math.round((h.cold / h.resolved) * 100)}% cold (${h.cold} of ${h.resolved})` +
                (h.total > h.resolved ? ` · ${h.total - h.resolved} no result` : ''),
        };

  // Sparse axis: ~6 labels, always including the oldest and newest bucket. The
  // last regular label is dropped when it would crowd the (right-aligned) end
  // label — otherwise they overlap whenever count isn't a multiple of step.
  const step = Math.max(1, Math.ceil(count / 6));
  // When the label stride is a whole number of days, every label lands on the
  // same clock time ("5 PM" six times at 30d) — pure noise, and the day markers
  // already carry the date. Drop the row entirely in that case.
  const axisRepeats = bucketSeconds < 86_400 && (step * bucketSeconds) % 86_400 === 0;
  const axis = axisRepeats
    ? []
    : slots
        .map((s, i) => ({ s, i }))
        .filter(({ i }) => i === count - 1 || (i % step === 0 && count - 1 - i >= step * 0.6));

  return (
    <div className="card" style={{ padding: '12px 16px', marginBottom: 10 }}>
      <div
        className="muted"
        style={{ fontSize: 12, marginBottom: 6, display: 'flex', justifyContent: 'space-between', gap: 12 }}
      >
        <span>Cold rate — % of resolved connections that found fal cold</span>
        <span>
          {overall === null ? 'no verdicts' : <>overall {overall}% ({sumCold} of {sumResolved})</>}
        </span>
      </div>
      <div style={{ position: 'relative', paddingTop: 26, paddingLeft: 30 }}>
        <BarTooltip tip={tip} />
        {/* Fixed 0/50/100% gridlines — the y-scale never moves. */}
        {[0, 50, 100].map((g) => (
          <div
            key={g}
            style={{
              position: 'absolute',
              left: 30,
              right: 0,
              top: 26 + ((100 - g) / 100) * H,
              borderTop: `1px ${g === 0 ? 'solid' : 'dashed'} var(--border)`,
              pointerEvents: 'none',
            }}
          >
            <span
              style={{
                position: 'absolute',
                left: -30,
                top: -7,
                fontSize: 10,
                color: 'var(--muted)',
              }}
            >
              {g}%
            </span>
          </div>
        ))}
        <div
          style={{ position: 'relative', display: 'flex', alignItems: 'flex-end', gap: 1, height: H }}
          onMouseLeave={() => setHover(null)}
          role="img"
          aria-label={`cold rate per ${bucketLabel} bucket, ${overall ?? 0}% overall`}
        >
          {/* Day boundaries: line at the bucket's LEFT edge (i/count, not the
              bar-center i+0.5 the axis labels use) — the day starts there. */}
          {dayStarts.map(({ i, date }) => (
            <div
              key={`day-${i}`}
              style={{
                position: 'absolute',
                left: `${(i / count) * 100}%`,
                top: -6,
                bottom: 0,
                borderLeft: '1px solid rgba(230, 232, 236, 0.28)',
                pointerEvents: 'none',
              }}
            >
              <span
                style={{
                  position: 'absolute',
                  left: 4,
                  top: -2,
                  fontSize: 10,
                  fontWeight: 600,
                  color: 'var(--muted)',
                  whiteSpace: 'nowrap',
                  // The plot's top band is empty at any realistic cold rate;
                  // the chip keeps the label readable if a bar ever reaches it.
                  background: 'var(--panel)',
                  padding: '0 3px',
                  borderRadius: 2,
                }}
              >
                {date.toLocaleDateString([], { month: 'short', day: 'numeric' })}
              </span>
            </div>
          ))}
          {slots.map((s, i) => {
            const pct = pctOf(s);
            return (
              <div
                key={s.start}
                onMouseEnter={() => setHover(i)}
                style={{ flex: 1, height: '100%', display: 'flex', alignItems: 'flex-end', minWidth: 2 }}
              >
                <div
                  style={{
                    width: '100%',
                    height: pct === null ? 2 : Math.max(2, (pct / 100) * H),
                    borderRadius: 1,
                    background: pct === null ? STUB : COLD,
                    // Volume shading: full opacity at the busiest bucket, floor
                    // at .3 so a single cold connection stays visible.
                    opacity: pct === null ? 1 : hover === i ? 1 : 0.3 + 0.7 * (s.total / maxTotal),
                  }}
                />
              </div>
            );
          })}
        </div>
        <div style={{ position: 'relative', height: axis.length === 0 ? 0 : 14, marginTop: 4 }}>
          {axis.map(({ s, i }) => (
            <span
              key={s.start}
              style={{
                position: 'absolute',
                left: `${((i + 0.5) / count) * 100}%`,
                transform: i === count - 1 ? 'translateX(-100%)' : 'translateX(-50%)',
                fontSize: 10,
                color: 'var(--muted)',
                whiteSpace: 'nowrap',
              }}
            >
              {fmtAxis(s.date)}
            </span>
          ))}
        </div>
      </div>
      <div className="muted" style={{ fontSize: 11, marginTop: 6 }}>
        One bar per {bucketLabel}. Fainter bars = fewer connections in that bucket; flat 2px = no
        verdicts.
      </div>
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
