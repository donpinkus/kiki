import { useCallback, useEffect, useMemo, useState } from 'react';
import Markdown from 'react-markdown';
import { listTestRuns, type TestRun } from '../api';

// Brush-test battery gallery. Deliberately NO pass/fail semantics (per Donald
// 2026-07-15): runs are published from BrushHarness (publish-run.sh), and this
// page exists for fast visual inspection — one run as a grid, two runs as
// side-by-sides, or one scene as a progression across every run. Clicking any
// thumbnail opens a lightbox with the FULL scene description and ←/→
// navigation through the collection being viewed.
//
// Scene descriptions travel WITH each run (harness manifest.json → per-image
// `description`), so they stay in lockstep with the scene definitions; for
// runs published before a description existed, we fall back to the newest
// known description for that scene name.

const shortSha = (sha: string | null) => (sha ? sha.slice(0, 7) : '—');
const fmtWhen = (iso: string) => new Date(iso).toLocaleString();
const runLabel = (r: TestRun) => `#${r.id} · ${shortSha(r.git_sha)} · ${fmtWhen(r.created_at)}`;

interface LightboxItem {
  blobKey: string;
  title: string;            // scene name
  description: string | null;
  subtitle: string;         // run label (+ note where useful)
}

function Lightbox({ items, index, onClose, onIndex }: {
  items: LightboxItem[];
  index: number;
  onClose: () => void;
  onIndex: (i: number) => void;
}) {
  const item = items[index];
  const prev = useCallback(() => onIndex(Math.max(0, index - 1)), [index, onIndex]);
  const next = useCallback(() => onIndex(Math.min(items.length - 1, index + 1)), [index, items.length, onIndex]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
      else if (e.key === 'ArrowLeft') prev();
      else if (e.key === 'ArrowRight') next();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose, prev, next]);

  if (!item) return null;
  return (
    <div className="lightbox-backdrop" onClick={onClose}>
      <div className="lightbox-panel" onClick={(e) => e.stopPropagation()}>
        <div className="lightbox-head">
          <span className="scene-name">{item.title}</span>
          <span className="muted" style={{ fontSize: 12 }}>{item.subtitle}</span>
          <span className="spacer" />
          <button className="lightbox-close" onClick={onClose} aria-label="Close">×</button>
        </div>
        {item.description && (
          <div className="lightbox-desc">
            <Markdown>{item.description}</Markdown>
          </div>
        )}
        <div className="lightbox-img-wrap">
          <img src={`/blobs/${item.blobKey}`} alt={item.title} />
          <button className="lightbox-nav prev" onClick={prev} disabled={index === 0} aria-label="Previous">‹</button>
          <button className="lightbox-nav next" onClick={next} disabled={index === items.length - 1} aria-label="Next">›</button>
        </div>
        <div className="lightbox-foot">
          <span>{index + 1} / {items.length}</span>
          <span className="spacer" />
          <a href={`/blobs/${item.blobKey}`} target="_blank" rel="noreferrer">open full size ↗</a>
        </div>
      </div>
    </div>
  );
}

function SceneImage({ blobKey, caption, onClick }: { blobKey: string; caption?: string; onClick: () => void }) {
  return (
    <div>
      <button className="tests-img-button" onClick={onClick}>
        <img src={`/blobs/${blobKey}`} alt={caption ?? blobKey} className="tests-img" />
      </button>
      {caption && <div className="tests-img-caption">{caption}</div>}
    </div>
  );
}

/** Scene title + the description's SUMMARY line (descriptions are markdown; line 1
 * is a plain sentence by authoring convention). The full structured description
 * renders in the lightbox — click through for it; title attr gives a quick peek. */
function SceneHeader({ name, description }: { name: string; description: string | null }) {
  const summary = description?.split('\n')[0] ?? null;
  return (
    <div>
      <div className="scene-name">{name}</div>
      {summary ? (
        <div className="scene-desc" title={description ?? undefined}>{summary}</div>
      ) : (
        <div className="scene-desc">&nbsp;</div>
      )}
    </div>
  );
}

export function Tests() {
  const [runs, setRuns] = useState<TestRun[] | null>(null);
  const [runAId, setRunAId] = useState<string | null>(null);
  const [runBId, setRunBId] = useState<string | 'none'>('none');
  const [scene, setScene] = useState<string | 'grid'>('grid');
  const [lightbox, setLightbox] = useState<{ items: LightboxItem[]; index: number } | null>(null);

  useEffect(() => {
    listTestRuns().then((r) => {
      setRuns(r.runs);
      if (r.runs.length > 0) setRunAId(r.runs[0].id);
    });
  }, []);

  const runA = useMemo(() => runs?.find((r) => r.id === runAId) ?? null, [runs, runAId]);
  const runB = useMemo(() => (runBId === 'none' ? null : runs?.find((r) => r.id === runBId) ?? null), [runs, runBId]);

  const allScenes = useMemo(() => {
    const names = new Set<string>();
    for (const r of runs ?? []) for (const img of r.images) names.add(img.scene);
    return [...names].sort();
  }, [runs]);

  // Prefer the NEWEST description per scene (runs arrive newest-first), falling
  // back to the run's own copy — keeps rendering consistent across old runs as
  // description formatting evolves (e.g. the markdown switch).
  const descFor = useMemo(() => {
    const m = new Map<string, string>();
    for (const r of runs ?? []) {
      for (const img of r.images) {
        if (img.description && !m.has(img.scene)) m.set(img.scene, img.description);
      }
    }
    return (sceneName: string, own?: string | null) => m.get(sceneName) ?? own ?? null;
  }, [runs]);

  if (!runs) return <div className="container muted">Loading…</div>;
  if (runs.length === 0)
    return (
      <div className="container muted">
        No test runs yet — publish one from the Mac:{' '}
        <code>ios/Packages/CanvasModule/BrushHarness/publish-run.sh "note"</code>
      </div>
    );

  const imageFor = (r: TestRun | null, sceneName: string) => r?.images.find((i) => i.scene === sceneName) ?? null;

  /** All scenes of one run as a lightbox collection (grid + side-by-side clicks). */
  const runItems = (r: TestRun): LightboxItem[] =>
    r.images.map((img) => ({
      blobKey: img.blob_key,
      title: img.scene,
      description: descFor(img.scene, img.description),
      subtitle: runLabel(r),
    }));

  /** One scene across all runs, oldest → newest (progression clicks). */
  const progressionItems = (sceneName: string): LightboxItem[] =>
    [...runs].reverse().flatMap((r) => {
      const img = imageFor(r, sceneName);
      return img
        ? [{
            blobKey: img.blob_key,
            title: sceneName,
            description: descFor(sceneName, img.description),
            subtitle: `${runLabel(r)}${r.note ? ` — ${r.note}` : ''}`,
          }]
        : [];
    });

  const openRunImage = (r: TestRun, sceneName: string) => {
    const items = runItems(r);
    const idx = items.findIndex((i) => i.title === sceneName);
    if (idx >= 0) setLightbox({ items, index: idx });
  };

  return (
    <div className="container">
      <div className="tests-controls">
        <label>
          Run
          <select value={runAId ?? ''} onChange={(e) => setRunAId(e.target.value)}>
            {runs.map((r) => (
              <option key={r.id} value={r.id}>{runLabel(r)}</option>
            ))}
          </select>
        </label>
        <label>
          Compare with
          <select value={runBId} onChange={(e) => setRunBId(e.target.value as string | 'none')}>
            <option value="none">— none —</option>
            {runs.filter((r) => r.id !== runAId).map((r) => (
              <option key={r.id} value={r.id}>{runLabel(r)}</option>
            ))}
          </select>
        </label>
        <label>
          Scene
          <select value={scene} onChange={(e) => setScene(e.target.value)}>
            <option value="grid">— all (grid) —</option>
            {allScenes.map((s) => (
              <option key={s} value={s}>{s} (progression)</option>
            ))}
          </select>
        </label>
      </div>

      {runA?.note && <div className="tests-note">Run note: {runA.note}</div>}

      {scene !== 'grid' ? (
        // Progression: one scene across every run, oldest → newest.
        <div>
          <div className="scene-card" style={{ marginBottom: 14, padding: '10px 12px' }}>
            <SceneHeader name={scene} description={descFor(scene)} />
          </div>
          <div style={{ display: 'flex', gap: 14, overflowX: 'auto', paddingBottom: 8 }}>
            {[...runs].reverse().map((r) => {
              const img = imageFor(r, scene);
              return (
                <div key={r.id} style={{ minWidth: 300, maxWidth: 340, flexShrink: 0 }}>
                  {img ? (
                    <SceneImage
                      blobKey={img.blob_key}
                      caption={`${runLabel(r)}${r.note ? ` — ${r.note}` : ''}`}
                      onClick={() => {
                        const items = progressionItems(scene);
                        const idx = items.findIndex((i) => i.blobKey === img.blob_key);
                        if (idx >= 0) setLightbox({ items, index: idx });
                      }}
                    />
                  ) : (
                    <div className="muted" style={{ aspectRatio: '1', display: 'flex', alignItems: 'center', justifyContent: 'center', border: '1px dashed var(--border)', borderRadius: 7 }}>
                      not in run #{r.id}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </div>
      ) : runB ? (
        // Side-by-side: every scene present in either run, A | B. Clicking an
        // image navigates within THAT run's scenes.
        <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
          {allScenes
            .filter((s) => imageFor(runA, s) || imageFor(runB, s))
            .map((s) => (
              <div key={s} className="scene-card">
                <SceneHeader name={s} description={descFor(s, imageFor(runA, s)?.description)} />
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
                  {[runA, runB].map((r, i) => {
                    const img = r ? imageFor(r, s) : null;
                    return img && r ? (
                      <SceneImage key={i} blobKey={img.blob_key} caption={runLabel(r)} onClick={() => openRunImage(r, s)} />
                    ) : (
                      <div key={i} className="muted" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', border: '1px dashed var(--border)', borderRadius: 7 }}>
                        not in this run
                      </div>
                    );
                  })}
                </div>
              </div>
            ))}
        </div>
      ) : (
        // Single-run grid.
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: 16 }}>
          {(runA?.images ?? []).map((img) => (
            <div key={img.scene} className="scene-card">
              <SceneHeader name={img.scene} description={descFor(img.scene, img.description)} />
              <SceneImage blobKey={img.blob_key} onClick={() => runA && openRunImage(runA, img.scene)} />
            </div>
          ))}
        </div>
      )}

      {lightbox && (
        <Lightbox
          items={lightbox.items}
          index={lightbox.index}
          onClose={() => setLightbox(null)}
          onIndex={(i) => setLightbox({ ...lightbox, index: i })}
        />
      )}
    </div>
  );
}
