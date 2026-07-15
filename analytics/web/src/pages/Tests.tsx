import { useEffect, useMemo, useState } from 'react';
import { listTestRuns, type TestRun } from '../api';

// Brush-test battery gallery. Deliberately NO pass/fail semantics (per Donald
// 2026-07-15): runs are published from BrushHarness (publish-run.sh), and this
// page exists for fast visual inspection — one run as a grid, two runs as
// side-by-sides, or one scene as a progression across every run.

const shortSha = (sha: string | null) => (sha ? sha.slice(0, 7) : '—');
const fmtWhen = (iso: string) => new Date(iso).toLocaleString();

function runLabel(r: TestRun): string {
  return `#${r.id} · ${shortSha(r.git_sha)} · ${fmtWhen(r.created_at)}`;
}

function SceneImage({ blobKey, caption }: { blobKey: string; caption?: string }) {
  return (
    <div>
      <a href={`/blobs/${blobKey}`} target="_blank" rel="noreferrer">
        <img
          src={`/blobs/${blobKey}`}
          alt={caption ?? blobKey}
          style={{ width: '100%', aspectRatio: '1', objectFit: 'contain', background: '#fff', display: 'block', borderRadius: 6, border: '1px solid #ddd' }}
        />
      </a>
      {caption && <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>{caption}</div>}
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

  if (!runs) return <div className="muted">Loading…</div>;
  if (runs.length === 0)
    return (
      <div className="muted">
        No test runs yet — publish one from the Mac:{' '}
        <code>ios/Packages/CanvasModule/BrushHarness/publish-run.sh "note"</code>
      </div>
    );

  const imageFor = (r: TestRun | null, sceneName: string) => r?.images.find((i) => i.scene === sceneName) ?? null;

  return (
    <div>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap', marginBottom: 12 }}>
        <label>
          Run{' '}
          <select value={runAId ?? ''} onChange={(e) => setRunAId(e.target.value)}>
            {runs.map((r) => (
              <option key={r.id} value={r.id}>{runLabel(r)}</option>
            ))}
          </select>
        </label>
        <label>
          Compare with{' '}
          <select value={runBId} onChange={(e) => setRunBId(e.target.value as string | 'none')}>
            <option value="none">— none —</option>
            {runs.filter((r) => r.id !== runAId).map((r) => (
              <option key={r.id} value={r.id}>{runLabel(r)}</option>
            ))}
          </select>
        </label>
        <label>
          Scene{' '}
          <select value={scene} onChange={(e) => setScene(e.target.value)}>
            <option value="grid">— all (grid) —</option>
            {allScenes.map((s) => (
              <option key={s} value={s}>{s} (progression)</option>
            ))}
          </select>
        </label>
      </div>

      {runA?.note && <div className="muted" style={{ marginBottom: 12 }}>Run note: {runA.note}</div>}

      {scene !== 'grid' ? (
        // Progression: one scene across every run, oldest → newest.
        <div style={{ display: 'flex', gap: 12, overflowX: 'auto', paddingBottom: 8 }}>
          {[...runs].reverse().map((r) => {
            const img = imageFor(r, scene);
            return (
              <div key={r.id} style={{ minWidth: 280, maxWidth: 320, flexShrink: 0 }}>
                {img ? (
                  <SceneImage blobKey={img.blob_key} caption={`${runLabel(r)}${r.note ? ` — ${r.note}` : ''}`} />
                ) : (
                  <div className="muted" style={{ aspectRatio: '1', display: 'flex', alignItems: 'center', justifyContent: 'center', border: '1px dashed #ccc', borderRadius: 6 }}>
                    not in run #{r.id}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      ) : runB ? (
        // Side-by-side: every scene present in either run, A | B.
        <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
          {allScenes
            .filter((s) => imageFor(runA, s) || imageFor(runB, s))
            .map((s) => (
              <div key={s}>
                <div style={{ fontWeight: 600, marginBottom: 6 }}>{s}</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, maxWidth: 900 }}>
                  {[runA, runB].map((r, i) => {
                    const img = imageFor(r, s);
                    return img ? (
                      <SceneImage key={i} blobKey={img.blob_key} caption={r ? runLabel(r) : ''} />
                    ) : (
                      <div key={i} className="muted" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', border: '1px dashed #ccc', borderRadius: 6 }}>
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
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: 16 }}>
          {(runA?.images ?? []).map((img) => (
            <div key={img.scene}>
              <div style={{ fontWeight: 600, marginBottom: 4 }}>{img.scene}</div>
              <SceneImage blobKey={img.blob_key} />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
