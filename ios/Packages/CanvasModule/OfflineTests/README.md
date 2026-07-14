# CanvasModule offline verification

`BrushDynamics.swift` (the sensor+curve keystone engine) and `WetKM.swift` (the wet brush's
spectral Kubelka-Munk mixing + premultiplied-`_srgb`-texel recovery) are **pure Swift (no
UIKit/Metal)**, so they can be verified on macOS even though `CanvasModule` itself is
iOS-only and won't `swift build` on the host. This dir holds a standalone harness that
asserts the shipped math against reference values (per `feedback_verify_shader_color_offline`).

It is **not** a SwiftPM target (SwiftPM only builds `Sources/`+`Tests/`), so it never affects
the app build. Run it by hand:

```bash
cd ios/Packages/CanvasModule/OfflineTests
swiftc ../Sources/CanvasModule/BrushDynamics.swift ../Sources/CanvasModule/WetKM.swift main.swift -o /tmp/bdtest && /tmp/bdtest
```

Expect `ALL PASSED`. Re-run after any change to the fold math, combine modes, sensor
normalization, the LUM/LUT bake, the KM tables/mix, or the texel-recovery math. The `1e-3`
tolerance on the gamma-curve checks reflects 256-entry LUT quantization (Krita's curve LUT
is the same resolution), not a defect.

Reference: `documents/research/krita-brush/PLAN.md` §2.1 (the keystone) and
`documents/research/krita-brush/02-sensor-curve-architecture.md`.
