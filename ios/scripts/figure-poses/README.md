# Figure pose presets

`ios/Kiki/Figure/Poses/figure_poses.json` is generated — do not hand-edit.

Source: Quaternius **Universal Animation Library [Standard]** (CC0 1.0, licence
copied next to the JSON). Its `Unreal-Godot/UAL1_Standard.glb` carries 43 clips
on the exact 65-joint skeleton of the bundled Universal Base Characters, so a
frame of any clip is a valid pose for both bodies. Free download without a
login (itch's download flow; the page is
https://quaternius.itch.io/universal-animation-library).

Regenerate:

```bash
blender -b --python ios/scripts/figure-poses/extract_poses.py -- \
  --anim "/path/to/Universal Animation Library[Standard]/Unreal-Godot/UAL1_Standard.glb" \
  --spec ios/scripts/figure-poses/poses.spec.json \
  --out  ios/Kiki/Figure/Poses/figure_poses.json
```

`poses.spec.json` maps `id/name/category` → `clip@frame` (+ optional `yaw` in
radians for poses that read best turned, e.g. lying/swimming, and `mirror` —
the mirror path is UNVERIFIED: it assumes the `_l`/`_r` bone frames are exact
reflections; check the result before shipping a mirrored pose).
Each pose stores per-bone deltas from the rig's own rest orientation
(`delta = rest⁻¹ · posed`, parent-relative glTF frame), which is what
`FigureScene.apply` composes back — so the values are exporter-consistent and
transfer between rigs whose rest poses differ (male/female/animation rig).

To pick frames: render a contact sheet of every clip at a few fractions with
Blender Workbench (see the 2026-09-13 session's `sheet.py` recipe: import the
GLB, ortho camera at (0,-10,0.9) looking +Y, `frame_set`, `render.render`).
