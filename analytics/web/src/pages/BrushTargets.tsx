import { useCallback, useEffect, useRef, useState } from 'react';
import Markdown from 'react-markdown';
import {
  createBrushTarget, deleteBrushTarget, deleteBrushTargetImage, listBrushTargets,
  updateBrushTarget, updateBrushTargetImage, uploadBrushTargetImages,
  type BrushTarget, type BrushTargetImage,
} from '../api';

// Brush clone targets: per-brush briefs for recreating Procreate-style brushes.
// Donald creates a target (name + notes), uploads screenshots of the reference
// stroke + the Procreate Brush Studio settings panes, and annotates each image.
// Claude pulls everything via BrushHarness/fetch-targets.sh, builds a preset,
// and posts recreation renders back as kind:'attempt' — shown here beside the
// references for side-by-side judgment.

const KINDS: BrushTargetImage['kind'][] = ['reference', 'settings', 'attempt'];
const STATUSES = ['todo', 'in_progress', 'matched'] as const;
const fmtWhen = (iso: string) => new Date(iso).toLocaleString();

function ImageCard({ img, onChanged }: { img: BrushTargetImage; onChanged: () => void }) {
  const [label, setLabel] = useState(img.label ?? '');
  const [note, setNote] = useState(img.note ?? '');
  const dirty = label !== (img.label ?? '') || note !== (img.note ?? '');
  return (
    <div className="scene-card" style={{ width: 260 }}>
      <a href={`/blobs/${img.blob_key}`} target="_blank" rel="noreferrer">
        <img src={`/blobs/${img.blob_key}`} style={{ width: '100%', borderRadius: 6, display: 'block' }} loading="lazy" />
      </a>
      <div style={{ display: 'flex', gap: 6, alignItems: 'center', marginTop: 6 }}>
        <select value={img.kind} onChange={async (e) => { await updateBrushTargetImage(img.id, { kind: e.target.value }); onChanged(); }}>
          {KINDS.map((k) => <option key={k} value={k}>{k}</option>)}
        </select>
        <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="label" style={{ flex: 1, minWidth: 0 }} />
      </div>
      <textarea
        value={note}
        onChange={(e) => setNote(e.target.value)}
        placeholder="notes for this screenshot (settings values, what to look at…)"
        rows={2}
        style={{ width: '100%', marginTop: 6, fontSize: 12 }}
      />
      <div style={{ display: 'flex', gap: 8, marginTop: 4 }}>
        {dirty && (
          <button onClick={async () => { await updateBrushTargetImage(img.id, { label, note }); onChanged(); }}>Save</button>
        )}
        <span className="spacer" />
        <button
          className="danger"
          onClick={async () => { if (confirm('Delete this image?')) { await deleteBrushTargetImage(img.id); onChanged(); } }}
        >Delete</button>
      </div>
    </div>
  );
}

function TargetPanel({ target, onChanged }: { target: BrushTarget; onChanged: () => void }) {
  const [note, setNote] = useState(target.note ?? '');
  const [editingNote, setEditingNote] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [uploadKind, setUploadKind] = useState('reference');
  const fileRef = useRef<HTMLInputElement>(null);
  useEffect(() => { setNote(target.note ?? ''); setEditingNote(false); }, [target.id]);

  const upload = async (files: FileList | null) => {
    if (!files || files.length === 0) return;
    setUploading(true);
    try {
      await uploadBrushTargetImages(target.id, Array.from(files), uploadKind);
      onChanged();
    } finally {
      setUploading(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  const groups: { title: string; kind: BrushTargetImage['kind'] }[] = [
    { title: 'Reference strokes', kind: 'reference' },
    { title: 'Procreate settings', kind: 'settings' },
    { title: 'Recreation attempts (Claude)', kind: 'attempt' },
  ];

  return (
    <div>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <h2 style={{ margin: 0 }}>{target.name}</h2>
        <select
          value={target.status}
          onChange={async (e) => { await updateBrushTarget(target.id, { status: e.target.value }); onChanged(); }}
        >
          {STATUSES.map((st) => <option key={st} value={st}>{st.replace('_', ' ')}</option>)}
        </select>
        <span className="muted" style={{ fontSize: 12 }}>updated {fmtWhen(target.updated_at)}</span>
        <span className="spacer" />
        <label style={{ display: 'flex', gap: 6, alignItems: 'center', fontSize: 13 }}>
          upload as
          <select value={uploadKind} onChange={(e) => setUploadKind(e.target.value)}>
            <option value="reference">reference</option>
            <option value="settings">settings</option>
          </select>
        </label>
        <input ref={fileRef} type="file" accept="image/*" multiple onChange={(e) => upload(e.target.files)} disabled={uploading} />
        <button
          className="danger"
          onClick={async () => {
            if (confirm(`Delete target "${target.name}" and all its images?`)) { await deleteBrushTarget(target.id); onChanged(); }
          }}
        >Delete target</button>
      </div>

      <div style={{ marginTop: 12 }}>
        {editingNote ? (
          <div>
            <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={8} style={{ width: '100%' }}
              placeholder="Brush brief: Procreate settings as text, what the brush should feel like, feedback on attempts…" />
            <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
              <button onClick={async () => { await updateBrushTarget(target.id, { note }); setEditingNote(false); onChanged(); }}>Save notes</button>
              <button onClick={() => { setNote(target.note ?? ''); setEditingNote(false); }}>Cancel</button>
            </div>
          </div>
        ) : (
          <div onClick={() => setEditingNote(true)} style={{ cursor: 'text' }} title="Click to edit">
            {target.note
              ? <div className="lightbox-desc" style={{ maxWidth: 900 }}><Markdown>{target.note}</Markdown></div>
              : <span className="muted">No notes yet — click to add the brush brief (settings text, feel, feedback).</span>}
          </div>
        )}
      </div>

      {groups.map(({ title, kind }) => {
        const imgs = target.images.filter((i) => i.kind === kind);
        if (imgs.length === 0 && kind === 'attempt') return null;
        return (
          <div key={kind} style={{ marginTop: 18 }}>
            <h3 style={{ marginBottom: 8 }}>{title} {imgs.length > 0 && <span className="muted" style={{ fontWeight: 400 }}>({imgs.length})</span>}</h3>
            {imgs.length === 0
              ? <span className="muted" style={{ fontSize: 13 }}>None yet.</span>
              : <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
                  {imgs.map((img) => <ImageCard key={img.id} img={img} onChanged={onChanged} />)}
                </div>}
          </div>
        );
      })}
    </div>
  );
}

export function BrushTargets() {
  const [targets, setTargets] = useState<BrushTarget[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [newName, setNewName] = useState('');
  const [err, setErr] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const { targets } = await listBrushTargets();
      setTargets(targets);
      setSelected((cur) => cur && targets.some((t) => t.id === cur) ? cur : (targets[0]?.id ?? null));
      setErr(null);
    } catch (e) {
      setErr((e as Error).message);
    }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);

  const create = async () => {
    const name = newName.trim();
    if (!name) return;
    const { id } = await createBrushTarget(name, '');
    setNewName('');
    await refresh();
    setSelected(id);
  };

  const current = targets.find((t) => t.id === selected) ?? null;

  return (
    <div className="page">
      <h1>Brush targets</h1>
      <p className="muted" style={{ maxWidth: 820 }}>
        One entry per brush to clone. Upload stroke-sample screenshots and Procreate Brush Studio
        settings panes, and write the brief in the notes. Claude pulls targets with
        <code> BrushHarness/fetch-targets.sh</code>, builds a preset, and posts recreation renders
        back as <em>attempts</em> for side-by-side review here.
      </p>
      {err && <p className="error">{err}</p>}
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', margin: '12px 0' }}>
        <input value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="New target name (e.g. Procreate 6B Pencil)"
          onKeyDown={(e) => { if (e.key === 'Enter') void create(); }} style={{ width: 320 }} />
        <button onClick={create} disabled={!newName.trim()}>Create target</button>
      </div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 16 }}>
        {targets.map((t) => (
          <button key={t.id} onClick={() => setSelected(t.id)}
            className={t.id === selected ? 'chip chip-active' : 'chip'}>
            {t.name}
            <span className="muted" style={{ marginLeft: 6, fontSize: 11 }}>{t.status.replace('_', ' ')}</span>
          </button>
        ))}
        {targets.length === 0 && <span className="muted">No targets yet.</span>}
      </div>
      {current && <TargetPanel target={current} onChanged={refresh} />}
    </div>
  );
}
