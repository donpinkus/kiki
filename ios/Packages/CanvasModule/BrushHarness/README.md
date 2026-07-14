# BrushHarness — headless brush/color evaluation on macOS

Renders the **real shipped engine** (`CanvasRenderer` + `StrokeStampGenerator` +
`WetStrokeWalker`, compiled straight from `Sources/CanvasModule/`) headless on the Mac and
writes PNGs. Apple-silicon Macs share the iPad's GPU family, so **framebuffer fetch works
and the wet brush renders here** — unlike the iOS Simulator, where it no-ops.

This closes the brush-development loop without an iPad round-trip: edit engine code →
recompile (~seconds) → render the battery → look at the PNGs. Claude can run this and
read the PNGs directly.

Like `OfflineTests/`, this is **not** a SwiftPM target — it compiles the module sources
directly (`-D BRUSH_HARNESS` swaps `Bundle.module` resource lookup for the
`BRUSH_SHAPES_DIR` env var), so it never affects the app build.

## Run

```bash
cd ios/Packages/CanvasModule/BrushHarness
S=../Sources/CanvasModule
swiftc -O -D BRUSH_HARNESS \
  $S/DrawingEngine.swift $S/BrushDynamics.swift $S/BrushShapeCatalog.swift \
  $S/WetKM.swift $S/BrushFixture.swift $S/StrokeStampGenerator.swift $S/WetStrokeWalker.swift \
  $S/CanvasRenderer.swift main.swift -o /tmp/brushharness

BRUSH_SHAPES_DIR=$PWD/$S/Resources/BrushShapes /tmp/brushharness --out /tmp/brush-out
open /tmp/brush-out   # or Read the PNGs directly
```

Options:
- `--out <dir>` — PNG output directory (default `./output`).
- `--filter <substring>` — only run scenes/fixtures whose name contains the substring.
- `--fixtures <file-or-dir>` — replay recorded stroke fixtures (repeatable).

## The synthetic battery

| Scene | Shows |
|---|---|
| `dry-01-pressure` | pressure ramp/bell, taper, hardness 0 vs 1 |
| `dry-02-flow-vs-opacity` | the Glaze split: self-crossing loops at flow 0.25/opacity 1 vs flow 1/opacity 0.25; overlapping separate strokes build |
| `dry-03-dynamics` | size-from-pressure (gamma), scatter, per-stroke color jitter (3 ids → 3 jitters) |
| `dry-04-shapes` | chalk/charcoal/drybrush/pastel/ink tips (needs `BRUSH_SHAPES_DIR`; falls back to round without it) |
| `wet-01-blue-into-yellow` | spectral KM: wet blue dragged over yellow → green trail |
| `wet-02-smudge` | smudge (no new ink) pushing red into a gap, contaminating toward blue |
| `wet-03-mix-sweep` | Mix 0.2/0.5/0.9 contact rows for tuning |

## Fixtures (recorded strokes from the iPad)

Brush Studio → **Record strokes** captures every completed brush stroke (points +
pressure/tilt/azimuth/timing + full `BrushConfig`). Two ways off the iPad:

- **Upload (the closed loop / bug-report button)**: one tap posts the fixture JSON + a
  PNG snapshot of the canvas (plus an optional note) to Kiki Insights
  (`POST /ingest/fixture`, Bearer-authed). Pull them here with:

  ```bash
  ./fetch-fixtures.sh [N]          # newest N fixtures → ./fixtures/*.json + *.png
  /tmp/brushharness --fixtures ./fixtures --out /tmp/brush-out
  ```

  Auth: `ADMIN_PASSWORD` env var, else auto-read from the kiki-insights Railway vars.
  The PNG shows what Donald actually saw (for "it looked muddy *here*" descriptions);
  the JSON re-renders the exact gesture through the current engine.

- **Share…** (offline fallback): the iOS share sheet → AirDrop/Files, then
  `--fixtures path/to/file.json`.

Either way, "this stroke feels wrong" becomes a permanent, re-runnable test case while
you tune parameters.

Fixture format (`BrushFixture`): `{ schema: 1, name?, canvasSide?, strokes: [Stroke] }`
where `Stroke` is the engine's own Codable type. `canvasSide` defaults to 2048 (the app's
document side).

## Faithfulness notes

- **Positions are canvas pixels** (scale 1). On device, stroke points are view points and
  `canvasScale` maps them to the 2048² document; recorded fixtures store already-mapped
  canvas-pixel positions.
- Dry strokes replay through `commitStampsToCanvas` — the same path persistence-restore
  uses, applying the flow/opacity split like a live stroke's flatten.
- Wet strokes replay in 2-point batches with a GPU-queue drain between batches,
  approximating the device's ~8 ms inter-batch cadence (the CPU pickup samples committed
  paint; see pro-brush-roadmap "known tradeoffs" for why timing matters).
- What this can NOT validate: pencil feel/latency, 120 Hz behavior, touch handling,
  display gamut. That stays on-device.
