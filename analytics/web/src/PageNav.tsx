import { useEffect, useState, type ReactNode } from 'react';

/**
 * Sticky per-page table of contents.
 *
 * The Ops/Fleet/Launch pages are long stacks of widgets — 10 sections on Fleet
 * — and finding one meant scrolling and squinting. This gives every page a rail
 * of its own sections.
 *
 * How pages opt in: replace `<div className="section-title">X</div>` with
 * `<SectionTitle title="X" />`. That's the whole contract — no per-page list of
 * links to keep in sync with the sections themselves, which is the thing that
 * always rots. `PageNav` mounts ONCE in App.tsx and discovers the headings from
 * the DOM, so a section added, removed, or conditionally rendered shows up in
 * the rail correctly without anyone remembering to update it.
 *
 * DOM discovery rather than a React context registry buys two things that
 * matter here: document order comes free from querySelectorAll (a context
 * registry would need compareDocumentPosition anyway, since conditional
 * sections mount out of order), and headings nested inside fragments or
 * data-dependent branches need no provider plumbing.
 */

/** Rail is noise on a page with one or two sections. */
const MIN_SECTIONS = 3;
/** A heading this far down the viewport is the one you're "on". */
const ACTIVE_LINE_PX = 96;

const slugify = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 60) || 'section';

/**
 * A page section heading. Renders the same `.section-title` markup as before
 * plus the anchor + metadata `PageNav` reads.
 *
 * - `children` — controls that sit inline after the title (Ops' filter pills).
 * - `right` — controls pushed to the right edge (the "Exclude test accounts"
 *   checkboxes, the Capacity range select).
 * - `nav` — shorter label for the rail, when the heading is a full sentence.
 */
export function SectionTitle({
  title,
  nav,
  children,
  right,
  style,
}: {
  title: string;
  nav?: string;
  children?: ReactNode;
  right?: ReactNode;
  style?: React.CSSProperties;
}) {
  return (
    <div
      className="section-title"
      // Slug from `nav` when present: some titles interpolate live counts
      // ("Drawings (12)"), and an anchor id that changes as data loads would
      // break the rail's active highlight mid-scroll.
      id={slugify(nav ?? title)}
      data-toc-title={title}
      data-toc-nav={nav ?? title}
      style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 8, ...style }}
    >
      <span>{title}</span>
      {children}
      {right ? (
        <>
          <span style={{ flex: 1 }} />
          {right}
        </>
      ) : null}
    </div>
  );
}

interface NavItem {
  id: string;
  label: string;
}

export function PageNav() {
  const [items, setItems] = useState<NavItem[]>([]);
  const [active, setActive] = useState<string | null>(null);

  // Re-scan whenever the DOM changes: sections appear as data loads, and some
  // are conditional on the response (Fleet's Spend block, UserDetail's Image
  // providers). Only childList is observed — the scan itself writes element
  // ids, which would otherwise feed back into the observer.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const scan = () => {
      const seen = new Set<string>();
      const found: NavItem[] = [];
      document.querySelectorAll<HTMLElement>('[data-toc-title]').forEach((el) => {
        let id = el.id || slugify(el.dataset['tocTitle'] ?? '');
        // Two sections sharing a title would otherwise both anchor to the first.
        if (seen.has(id)) {
          let n = 2;
          while (seen.has(`${id}-${n}`)) n += 1;
          id = `${id}-${n}`;
        }
        seen.add(id);
        if (el.id !== id) el.id = id;
        found.push({ id, label: el.dataset['tocNav'] || el.dataset['tocTitle'] || id });
      });
      setItems((prev) =>
        prev.length === found.length && prev.every((p, i) => p.id === found[i].id && p.label === found[i].label)
          ? prev
          : found,
      );
    };
    scan();
    // setTimeout, not requestAnimationFrame: rAF callbacks don't run while the
    // tab is hidden, so a page loaded in a background tab would render all its
    // sections with the rescan never firing.
    const observer = new MutationObserver(() => {
      clearTimeout(timer);
      timer = setTimeout(scan, 50);
    });
    observer.observe(document.body, { childList: true, subtree: true });
    return () => {
      observer.disconnect();
      clearTimeout(timer);
    };
  }, []);

  // Scroll spy: the active section is the last heading above the active line.
  // A plain scroll handler beats IntersectionObserver here — headings are zero-
  // height targets, so IO's "is it visible" question is the wrong one.
  useEffect(() => {
    if (items.length < MIN_SECTIONS) return;
    const onScroll = () => {
      let current: string | null = items[0]?.id ?? null;
      for (const it of items) {
        const el = document.getElementById(it.id);
        if (el && el.getBoundingClientRect().top <= ACTIVE_LINE_PX) current = it.id;
      }
      // At the bottom of the page the last section may never cross the line.
      if (window.innerHeight + window.scrollY >= document.body.scrollHeight - 4) {
        current = items[items.length - 1]?.id ?? current;
      }
      setActive(current);
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll);
    return () => {
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
    };
  }, [items]);

  if (items.length < MIN_SECTIONS) return null;

  // scrollIntoView + the `scroll-margin-top` on .section-title[data-toc-title]
  // keeps the landing offset in CSS rather than duplicating it as JS math.
  const go = (id: string) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    setActive(id);
  };

  return (
    <nav className="page-nav" aria-label="Sections on this page">
      <div className="page-nav-head">On this page</div>
      {items.map((it) => (
        <button
          key={it.id}
          className={`page-nav-item${active === it.id ? ' active' : ''}`}
          onClick={() => go(it.id)}
          title={it.label}
        >
          {it.label}
        </button>
      ))}
    </nav>
  );
}
