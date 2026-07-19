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
const STATUS_LABEL: Record<BrushTarget['status'], string> = {
  todo: 'To do', in_progress: 'In progress', matched: 'Matched',
};
const fmtWhen = (iso: string) =>
  new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });

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
      <ol>
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
      <p>
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
  const [drag, setDrag] = useState(false);
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
      className={drag ? 'upload-zone dragging' : 'upload-zone'}
      tabIndex={0}
      onPaste={(e) => {
        const files = Array.from(e.clipboardData.files);
        if (files.length > 0) { e.preventDefault(); void doUpload(files); }
      }}
      onDragOver={(e) => { e.preventDefault(); setDrag(true); }}
      onDragLeave={() => setDrag(false)}
      onDrop={(e) => { e.preventDefault(); setDrag(false); void doUpload(Array.from(e.dataTransfer.files)); }}
    >
      <div className="upload-zone-head">
        <strong>{title}</strong>
        <span className="muted">{hint}</span>
      </div>
      <div className="upload-zone-actions">
        <button className="ghost" onClick={() => fileRef.current?.click()} disabled={busy}>Choose files…</button>
        <button className="ghost" onClick={() => void pasteFromClipboard()} disabled={busy}>Paste screenshot</button>
        <span className="muted">
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
    <div className="brush-img-card">
      <a className="brush-img-link" href={`/blobs/${img.blob_key}`} target="_blank" rel="noreferrer">
        <img src={`/blobs/${img.blob_key}`} loading="lazy" />
      </a>
      <div className="brush-img-meta">
        <div className="brush-img-row">
          <select value={img.kind} onChange={async (e) => { await updateBrushTargetImage(img.id, { kind: e.target.value }); onChanged(); }}>
            {KINDS.map((k) => <option key={k} value={k}>{k}</option>)}
          </select>
          <input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="label (e.g. Shape pane)" />
        </div>
        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="notes (settings values, what to look at…)"
          rows={2}
        />
        <div className="brush-img-row">
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
    </div>
  );
}

function TargetPanel({ target, onChanged }: { target: BrushTarget; onChanged: () => void }) {
  const [note, setNote] = useState(target.note ?? '');
  const [editingNote, setEditingNote] = useState(false);
  const [nameDraft, setNameDraft] = useState<string | null>(null); // null = not renaming
  useEffect(() => { setNote(target.note ?? ''); setEditingNote(false); setNameDraft(null); }, [target.id]);

  const saveName = async () => {
    const name = nameDraft?.trim();
    setNameDraft(null);
    if (name && name !== target.name) {
      await updateBrushTarget(target.id, { name });
      onChanged();
    }
  };

  const groups: { title: string; kind: BrushTargetImage['kind']; hint: string }[] = [
    { title: 'Reference strokes', kind: 'reference', hint: 'real strokes drawn with the target brush' },
    { title: 'Procreate settings', kind: 'settings', hint: 'Brush Studio panes + shape/grain sources' },
    { title: 'Recreation attempts', kind: 'attempt', hint: 'renders posted back by Claude' },
  ];

  return (
    <div className="brush-detail">
      <div className="brush-detail-head">
        {nameDraft === null ? (
          <h2 onClick={() => setNameDraft(target.name)} title="Click to rename">
            {target.name} <span className="rename-hint">✎</span>
          </h2>
        ) : (
          <input
            className="rename-input" autoFocus value={nameDraft}
            onChange={(e) => setNameDraft(e.target.value)}
            onBlur={() => void saveName()}
            onKeyDown={(e) => {
              if (e.key === 'Enter') void saveName();
              if (e.key === 'Escape') setNameDraft(null);
            }}
          />
        )}
        <div className="seg">
          {STATUSES.map((st) => (
            <button
              key={st}
              className={st === target.status ? `seg-btn active st-${st}` : 'seg-btn'}
              onClick={async () => { await updateBrushTarget(target.id, { status: st }); onChanged(); }}
            >{STATUS_LABEL[st]}</button>
          ))}
        </div>
        <span className="spacer" />
        <span className="muted brush-updated">updated {fmtWhen(target.updated_at)}</span>
        <button
          className="danger"
          onClick={async () => {
            if (confirm(`Delete target "${target.name}" and all its images?`)) { await deleteBrushTarget(target.id); onChanged(); }
          }}
        >Delete target</button>
      </div>

      <div className="brush-brief">
        {editingNote ? (
          <div>
            <textarea value={note} onChange={(e) => setNote(e.target.value)} rows={8}
              placeholder={NOTES_PLACEHOLDER} />
            <div className="brush-brief-actions">
              <button onClick={async () => { await updateBrushTarget(target.id, { note }); setEditingNote(false); onChanged(); }}>Save notes</button>
              <button className="ghost" onClick={() => { setNote(target.note ?? ''); setEditingNote(false); }}>Cancel</button>
            </div>
          </div>
        ) : (
          <div className="brush-brief-body" onClick={() => setEditingNote(true)} title="Click to edit">
            {target.note
              ? <Markdown>{target.note}</Markdown>
              : <span className="muted">No notes yet — click to add the brush brief (Procreate name/set, size used, feel, feedback).</span>}
          </div>
        )}
      </div>

      <CaptureChecklist />

      <div className="upload-row">
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

      {groups.map(({ title, kind, hint }) => {
        const imgs = target.images.filter((i) => i.kind === kind);
        if (imgs.length === 0 && kind === 'attempt') return null;
        return (
          <section key={kind} className={`brush-group ${kind === 'attempt' ? 'attempt-group' : ''}`}>
            <div className="brush-group-head">
              <h3>{title}</h3>
              {imgs.length > 0 && <span className="count-badge">{imgs.length}</span>}
              <span className="muted">{hint}</span>
            </div>
            {imgs.length === 0
              ? <p className="muted brush-group-empty">None yet.</p>
              : <div className="brush-img-grid">
                  {imgs.map((img) => <ImageCard key={img.id} img={img} onChanged={onChanged} />)}
                </div>}
          </section>
        );
      })}
    </div>
  );
}

function kindCounts(t: BrushTarget) {
  const parts: string[] = [];
  for (const [kind, noun] of [['reference', 'ref'], ['settings', 'settings'], ['attempt', 'attempt']] as const) {
    const n = t.images.filter((i) => i.kind === kind).length;
    if (n > 0) parts.push(`${n} ${noun}${noun !== 'settings' && n !== 1 ? 's' : ''}`);
  }
  return parts.length > 0 ? parts.join(' · ') : 'no images yet';
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
    <div className="container wide">
      <h1 className="brush-title">Brushes</h1>
      <p className="muted brush-intro">
        One entry per brush to clone. Upload stroke-sample screenshots and Procreate Brush Studio
        settings panes, and write the brief in the notes. Claude pulls targets with
        <code> BrushHarness/fetch-targets.sh</code>, builds a preset, and posts recreation renders
        back as <em>attempts</em> for side-by-side review here.
      </p>
      {err && <p className="error">{err}</p>}
      <div className="brush-layout">
        <aside className="brush-sidebar">
          <div className="brush-create">
            <input value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="New target name…"
              onKeyDown={(e) => { if (e.key === 'Enter') void create(); }} />
            <button onClick={create} disabled={!newName.trim()}>Create</button>
          </div>
          {targets.length === 0
            ? <p className="muted brush-sidebar-empty">No targets yet — name one above (e.g. “Procreate 6B Pencil”).</p>
            : targets.map((t) => (
              <button key={t.id} onClick={() => setSelected(t.id)}
                className={t.id === selected ? 'target-item active' : 'target-item'}>
                <span className={`status-dot st-${t.status}`} title={STATUS_LABEL[t.status]} />
                <span className="target-item-body">
                  <span className="target-item-name">{t.name}</span>
                  <span className="target-item-meta muted">{kindCounts(t)}</span>
                </span>
              </button>
            ))}
        </aside>
        {current && <TargetPanel target={current} onChanged={refresh} />}
      </div>
    </div>
  );
}
