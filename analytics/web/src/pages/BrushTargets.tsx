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

const NOTES_PLACEHOLDER = `Brush brief — anything the screenshots don't say:
• Procreate name + brush set (e.g. "Peppermint — Sketching")
• Size / opacity the samples were drawn at
• How it feels: pressure response, texture, speed behavior
• Later: feedback on Claude's attempts (what's off, what's close)`;

// What to capture, priority-ordered. Shown inline so the capture session
// doesn't need a chat lookup.
function CaptureChecklist() {
  return (
    <details className="capture-guide">
      <summary>📸 What to capture (priority order)</summary>
      <ol style={{ margin: '8px 0 4px 18px', fontSize: 13, lineHeight: 1.6 }}>
        <li><strong>Shape + Grain source images</strong> — open Shape Source → Edit and Grain
          Source → Edit and screenshot the texture FULLSCREEN. These import into Kiki directly,
          so they're worth more than every settings pane combined.</li>
        <li><strong>Stroke samples</strong> (on white, brush at a normal size): light→hard
          pressure sweep · slow S-curve · fast flick · self-crossing scribble at ~50% opacity
          (shows glaze/blending) · one zoomed-in edge close-up.</li>
        <li><strong>Settings panes that matter most</strong>: Stroke Path · Shape · Grain ·
          Rendering (mode + blending) · Taper · Apple Pencil → Pressure · Wet Mix (only if it's
          a wet/blending brush).</li>
        <li>Skip unless unusual: Stabilization, Dynamics, Properties, Materials, About.</li>
      </ol>
      <p className="muted" style={{ fontSize: 12, margin: '6px 0 2px' }}>
        Screenshots beat video — each pane arrives sharp and complete. A screen recording works
        as a fallback (frames get extracted), but pause ~1s on each pane if you go that route.
      </p>
    </details>
  );
}

// Drag-drop + paste + file-pick upload area for one image kind.
function UploadZone({ targetId, kind, title, hint, onDone }: {
  targetId: string; kind: string; title: string; hint: string; onDone: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [flash, setFlash] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  const doUpload = async (files: File[]) => {
    const images = files.filter((f) => f.type.startsWith('image/'));
    if (images.length === 0) return;
    setBusy(true);
    try {
      await uploadBrushTargetImages(targetId, images, kind);
      setFlash(`${images.length} uploaded ✓`);
      setTimeout(() => setFlash(null), 2500);
      onDone();
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  };

  const pasteFromClipboard = async () => {
    try {
      const items = await navigator.clipboard.read();
      const files: File[] = [];
      for (const item of items) {
        const type = item.types.find((t) => t.startsWith('image/'));
        if (type) {
          const blob = await item.getType(type);
          files.push(new File([blob], `pasted-${Date.now()}.png`, { type }));
        }
      }
      if (files.length === 0) {
        setFlash('No image on the clipboard');
        setTimeout(() => setFlash(null), 2500);
      }
      await doUpload(files);
    } catch {
      setFlash('Clipboard blocked — focus this box + ⌘V, or Choose files');
      setTimeout(() => setFlash(null), 4000);
    }
  };

  return (
    <div
      className="upload-zone"
      tabIndex={0}
      onPaste={(e) => {
        const files = Array.from(e.clipboardData.files);
        if (files.length > 0) { e.preventDefault(); void doUpload(files); }
      }}
      onDragOver={(e) => e.preventDefault()}
      onDrop={(e) => { e.preventDefault(); void doUpload(Array.from(e.dataTransfer.files)); }}
    >
      <div style={{ display: 'flex', gap: 10, alignItems: 'baseline', flexWrap: 'wrap' }}>
        <strong style={{ fontSize: 13 }}>{title}</strong>
        <span className="muted" style={{ fontSize: 12 }}>{hint}</span>
      </div>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 8, flexWrap: 'wrap' }}>
        <button onClick={() => fileRef.current?.click()} disabled={busy}>Choose files…</button>
        <button onClick={() => void pasteFromClipboard()} disabled={busy}>Paste screenshot</button>
        <span className="muted" style={{ fontSize: 12 }}>
          {busy ? 'Uploading…' : flash ?? 'or drop images here / focus + ⌘V'}
        </span>
      </div>
      <input
        ref={fileRef} type="file" accept="image/*" multiple style={{ display: 'none' }}
        onChange={(e) => void doUpload(Array.from(e.target.files ?? []))}
      />
    </div>
  );
}

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
        <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="label (e.g. Shape pane)" style={{ flex: 1, minWidth: 0 }} />
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
  useEffect(() => { setNote(target.note ?? ''); setEditingNote(false); }, [target.id]);

  const rename = async () => {
    const name = prompt('Rename target', target.name)?.trim();
    if (name && name !== target.name) {
      await updateBrushTarget(target.id, { name });
      onChanged();
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
        <h2 style={{ margin: 0, cursor: 'pointer' }} onClick={rename} title="Click to rename">
          {target.name} <span className="muted" style={{ fontSize: 14 }}>✎</span>
        </h2>
        <select
          value={target.status}
          onChange={async (e) => { await updateBrushTarget(target.id, { status: e.target.value }); onChanged(); }}
        >
          {STATUSES.map((st) => <option key={st} value={st}>{st.replace('_', ' ')}</option>)}
        </select>
        <span className="muted" style={{ fontSize: 12 }}>updated {fmtWhen(target.updated_at)}</span>
        <span className="spacer" />
        <button
          className="danger"
          onClick={async () => {
            if (confirm(`Delete target "${target.name}" and all its images?`)) { await deleteBrushTarget(target.id); onChanged(); }
          }}
        >Delete target</button>
      </div>

      <CaptureChecklist />

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginTop: 12 }}>
        <UploadZone
          targetId={target.id} kind="reference" onDone={onChanged}
          title="Stroke samples"
          hint="pressure sweep · S-curve · fast flick · 50%-opacity scribble · edge close-up"
        />
        <UploadZone
          targetId={target.id} kind="settings" onDone={onChanged}
          title="Settings + source textures"
          hint="Shape/Grain editors fullscreen, then the settings panes"
        />
      </div>

      <div style={{ marginTop: 12 }}>
        {editingNote ? (
          <div>
            <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={8} style={{ width: '100%' }}
              placeholder={NOTES_PLACEHOLDER} />
            <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
              <button onClick={async () => { await updateBrushTarget(target.id, { note }); setEditingNote(false); onChanged(); }}>Save notes</button>
              <button onClick={() => { setNote(target.note ?? ''); setEditingNote(false); }}>Cancel</button>
            </div>
          </div>
        ) : (
          <div onClick={() => setEditingNote(true)} style={{ cursor: 'text' }} title="Click to edit">
            {target.note
              ? <div className="lightbox-desc" style={{ maxWidth: 900 }}><Markdown>{target.note}</Markdown></div>
              : <span className="muted">No notes yet — click to add the brush brief (Procreate name/set, size used, feel, feedback).</span>}
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
