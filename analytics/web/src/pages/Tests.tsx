import { useEffect, useMemo, useState } from 'react';
import { listTestRuns, type TestRun } from '../api';

// Brush-test battery gallery. Deliberately NO pass/fail semantics (per Donald
// 2026-07-15): runs are published from BrushHarness (publish-run.sh), and this
// page exists for fast visual inspection — one run as a grid, two runs as
// side-by-sides, or one scene as a progression across every run.
//
// Scene descriptions travel WITH each run (harness manifest.json → per-image
// `description`), so they stay in lockstep with the scene definitions; for
// runs published before a description existed, we fall back to the newest
// known description for that scene name.

const shortSha = (sha: string | null) => (sha ? sha.slice(0, 7) : '—');
const fmtWhen = (iso: string) => new Date(iso).toLocaleString();
const runLabel = (r: TestRun) => `#${r.id} · ${shortSha(r.git_sha)} · ${fmtWhen(r.created_at)}`;

function SceneImage({ blobKey, caption }: { blobKey: string; caption?: string }) {
  return (
    <div>
      <a href={`/blobs/${blobKey}`} target="_blank" rel="noreferrer">
        <img src={`/blobs/${blobKey}`} alt={caption ?? blobKey} className="tests-img" />
      </a>
      {caption && <div className="tests-img-caption">{caption}</div>}
    </div>
  );
}

/** Scene title + one-line description that expands on hover (title attr as backup). */
function SceneHeader({ name, description }: { name: string; description: string | null }) {
  return (
    <div>
      <div className="scene-name">{name}</div>
      {description ? (
        <div className="scene-desc" title={description}>{description}</div>
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

  // Newest available description per scene (runs arrive newest-first).
  const descFor = useMemo(() => {
    const m = new Map<string, string>();
    for (const r of runs ?? []) {
      for (const img of r.images) {
        if (img.description && !m.has(img.scene)) m.set(img.scene, img.description);
      }
    }
    return (sceneName: string, own?: string | null) => own ?? m.get(sceneName) ?? null;
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
                    <SceneImage blobKey={img.blob_key} caption={`${runLabel(r)}${r.note ? ` — ${r.note}` : ''}`} />
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
        // Side-by-side: every scene present in either run, A | B.
        <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
          {allScenes
            .filter((s) => imageFor(runA, s) || imageFor(runB, s))
            .map((s) => (
              <div key={s} className="scene-card">
                <SceneHeader name={s} description={descFor(s, imageFor(runA, s)?.description)} />
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
                  {[runA, runB].map((r, i) => {
                    const img = imageFor(r, s);
                    return img ? (
                      <SceneImage key={i} blobKey={img.blob_key} caption={r ? runLabel(r) : ''} />
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
              <SceneImage blobKey={img.blob_key} />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
