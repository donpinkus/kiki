# Plan: Debug ControlNet Comparison Mode

## Overview
Add a toggle that runs a second generation with controlnet strength=0 after the normal generation. A debug button (visible only when comparison mode is active or data exists) opens a full-screen 2x2 grid modal showing: original sketch, lineart, generated image, and no-controlnet image. All comparison failures surface clear error messages via alert.

---

## Architecture Decisions

**`compareWithoutControlNet` is a request-level flag, not a generation parameter.**
It lives on `GenerateRequest` / `ProviderRequest`, not on `AdvancedParameters`. It controls _how many_ generations to run, not _how_ a single generation runs. The toggle state lives on `AppCoordinator`.

**Debug button lives in ContentView, not ResultModule.**
ResultModule is a standalone SPM package focused on displaying generation results. Debug comparison is a main-app concern. The button overlays the result area from ContentView. No changes to ResultModule. Button only visible when `compareWithoutControlNet || hasComparisonData` — no UI clutter when the feature is off.

**One struct for comparison data, built in the pipeline.**
`ComparisonData` holds all 4 images + CN strength label. Built directly in the pipeline (which has access to everything: snapshot, downloaded images, generated image, CN strength from input). Stored as-is on the coordinator — no intermediate struct, no mapping step.

**Comparison errors are explicit, never silent.**
Every comparison failure surfaces a clear error message via SwiftUI alert. The primary generation is never affected. Backend errors pass through with their original message. iOS-side failures (download/decode) use the error's `localizedDescription`.

**Second workflow clones the already-configured first workflow.**
Don't rebuild from template. The first workflow already has the sketch filename, prompt, seed, and all parameters applied. Just `structuredClone()` it and override CN strength to 0.

**Second generation failure is non-fatal but reported.**
If the first gen succeeds but the second fails, the backend returns the primary result normally with the error in `comparisonError`. The user gets their image plus a clear alert.

**If both `comparisonImageUrl` and `comparisonError` are returned, prefer the image.** Defensive against backend bugs — success wins.

---

## Changes

### 1. Backend: Second generation when flag is set

**`backend/src/modules/providers/types.ts`:**
- Add `compareWithoutControlNet?: boolean` to `ProviderRequest`
- Add `comparisonImageUrl?: string` to `ProviderResponse`
- Add `comparisonError?: string` to `ProviderResponse`

**`backend/src/routes/generate.ts`:**
- Add `compareWithoutControlNet` to `generateBodySchema`: `{ type: 'boolean', nullable: true }`
- Add `compareWithoutControlNet?: boolean | null` to `GenerateBody` interface
- Pass `compareWithoutControlNet: compareWithoutControlNet ?? undefined` to `ProviderRequest`
- Include `comparisonImageUrl: result.comparisonImageUrl ?? null` in the success response
- Include `comparisonError: result.comparisonError ?? null` in the success response

**`backend/src/modules/providers/comfyui.ts`:**

After the first generation completes (after line 104 where seed is extracted), add comparison logic:

```
let comparisonImageUrl: string | undefined;
let comparisonError: string | undefined;

if (request.compareWithoutControlNet) {
  try {
    const compWorkflow = structuredClone(workflow);  // clone configured workflow
    compWorkflow[CONTROLNET_APPLY_NODE_ID].inputs['strength'] = 0;
    const compPromptId = await this.submitPrompt(baseUrl, compWorkflow);
    const compOutputs = await this.pollForResult(baseUrl, compPromptId);
    const compSaveOutput = compOutputs[SAVE_IMAGE_NODE_ID]?.images?.[0];
    if (compSaveOutput) {
      comparisonImageUrl = `${baseUrl}/view?filename=...`;  // same URL pattern as main image
    } else {
      comparisonError = 'Comparison generation completed but produced no image';
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    comparisonError = `Comparison generation failed: ${msg}`;
    console.warn(comparisonError);
  }
}
```

Include both `comparisonImageUrl` and `comparisonError` in the returned `ProviderResponse`.

### 2. iOS NetworkModule: Update request/response models

**`AdvancedParameters.swift`:** No changes.

**`GenerateRequest.swift`:**
- Add `public let compareWithoutControlNet: Bool?` property
- Add to init with default `nil`

**`GenerateResponse.swift`:**
- Add `public let comparisonImageURL: URL?` property
- Add `public let comparisonError: String?` property
- Add both to init with default `nil`

**`APIClient.swift` (`decodeSuccessResponse`):**
- Add `let comparisonImageUrl: String?` to the private `APIResponse` struct
- Add `let comparisonError: String?` to the private `APIResponse` struct
- Map: `let comparisonImageURL = decoded.comparisonImageUrl.flatMap { URL(string: $0) }`
- Pass both through to `GenerateResponse` init

### 3. iOS GenerationPipeline: Expand Output, download comparison images

**`GenerationPipeline.swift`:**

Add struct (used by both pipeline and coordinator):
```swift
struct ComparisonData {
    let snapshotImage: UIImage      // canvas snapshot that was sent
    let lineartImage: UIImage       // ControlNet preprocessor output
    let generatedImage: UIImage     // normal generation result
    let comparisonImage: UIImage    // generation with CN strength=0
    let controlNetStrength: Double  // the CN strength used (for label)
}
```

Expand `Input`:
- Add `let compareWithoutControlNet: Bool`

Expand `Output`:
- Add `let comparisonData: ComparisonData?` — nil when comparison mode is off or any step fails
- Add `let comparisonError: String?` — nil when comparison succeeded or wasn't requested

In `run()`, after downloading the main image (which remains required/throwing):
```swift
var comparisonData: ComparisonData? = nil
var comparisonError: String? = nil

if input.compareWithoutControlNet {
    if let backendError = response.comparisonError, response.comparisonImageURL == nil {
        // Backend-side failure — pass through the message
        comparisonError = backendError
    } else if let lineartURL = response.lineartImageURL,
              let comparisonURL = response.comparisonImageURL {
        do {
            let (lineartData, _) = try await URLSession.shared.data(from: lineartURL)
            let (compData, _) = try await URLSession.shared.data(from: comparisonURL)
            guard let lineartImage = UIImage(data: lineartData),
                  let compImage = UIImage(data: compData) else {
                throw PipelineError.imageDecodeFailed(byteCount: 0, url: comparisonURL)
            }
            let cnStrength = input.advancedParameters?.controlNetStrength
                ?? AdvancedParameters.defaultControlNetStrength
            comparisonData = ComparisonData(
                snapshotImage: snapshot.image,
                lineartImage: lineartImage,
                generatedImage: mainImage,
                comparisonImage: compImage,
                controlNetStrength: cnStrength
            )
        } catch {
            comparisonError = "Comparison download failed: \(error.localizedDescription)"
        }
    } else {
        comparisonError = "Server returned no comparison image URL"
    }
}
```

Note: `snapshot.image` is already in scope from the preparing phase. `mainImage` is the just-downloaded primary image.

### 4. iOS AppCoordinator: Store comparison data, add toggle state, show errors

**`AppCoordinator.swift`:**

Add state properties:
```swift
var comparisonData: ComparisonData?
var compareWithoutControlNet = false {
    didSet {
        if !compareWithoutControlNet {
            comparisonData = nil
            comparisonError = nil
        }
    }
}
var comparisonError: String?

var hasComparisonData: Bool { comparisonData != nil }
```

The `didSet` clears stale state when comparison mode is toggled off.

In `generate()`:
- Clear `comparisonError = nil` at the start (dismiss any previous error)
- Do NOT clear `comparisonData` at the start (keep old data visible in modal until replaced)
- Pass `compareWithoutControlNet: compareWithoutControlNet` into `GenerationPipeline.Input`
- After pipeline returns output:
  ```swift
  comparisonData = output.comparisonData  // nil if comparison off or failed
  if let error = output.comparisonError {
      comparisonError = error
  }
  ```

### 5. iOS AdvancedParametersPanel: Add toggle

**`AdvancedParametersPanel.swift`:**

Add a "Debug" section before the Reset section:
```swift
Section("Debug") {
    Toggle("Compare without ControlNet", isOn: $coordinator.compareWithoutControlNet)
}
```

Update the Reset button action to also reset: `coordinator.compareWithoutControlNet = false`
Update the Reset button `.disabled` condition to include: `&& !coordinator.compareWithoutControlNet`

### 6. iOS New View: DebugComparisonModal

**New file: `ios/Kiki/Views/DebugComparisonModal.swift`**

- Init takes `ComparisonData` and uses `@Environment(\.dismiss)`
- Full-screen dark background (`.background(Color.black)`)
- 2x2 grid using `LazyVGrid(columns: [.flexible(), .flexible()], spacing: 12)`:
  - Top-left: "Original Sketch" — `data.snapshotImage`
  - Top-right: "Lineart" — `data.lineartImage`
  - Bottom-left: "Generated (CN: {strength})" — `data.generatedImage`
  - Bottom-right: "Generated (CN: 0)" — `data.comparisonImage`
- Each cell: `Image(uiImage:).resizable().aspectRatio(contentMode: .fit)` with a small caption label below
- X button (`xmark.circle.fill`) top-trailing, dismisses the modal
- Presented via `.fullScreenCover` from ContentView

### 7. iOS ContentView: Wire up debug button, modal, and error alert

**`ContentView.swift`:**

Add state: `@State private var showDebugModal = false`

Overlay the debug button on the ResultView area — **only visible when comparison mode is on or data exists**:
```swift
ResultView(state: coordinator.resultState)
    .overlay(alignment: .topTrailing) {
        if coordinator.compareWithoutControlNet || coordinator.hasComparisonData {
            Button { showDebugModal = true } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(!coordinator.hasComparisonData)
            .opacity(coordinator.hasComparisonData ? 1 : 0.4)
            .padding(12)
        }
    }
```

Full-screen cover and error alert:
```swift
.fullScreenCover(isPresented: $showDebugModal) {
    if let data = coordinator.comparisonData {
        DebugComparisonModal(data: data)
    }
}
.alert(
    "Comparison Failed",
    isPresented: Binding(
        get: { coordinator.comparisonError != nil },
        set: { if !$0 { coordinator.comparisonError = nil } }
    )
) {
    Button("OK") { coordinator.comparisonError = nil }
} message: {
    Text(coordinator.comparisonError ?? "")
}
```

### 8. iOS APIClient: Increase resource timeout

**`APIClient.swift`:**
- Change `config.timeoutIntervalForResource = 60` → `120`
- This is `timeoutIntervalForResource` (session-level, can't be per-request). Two sequential backend generations can approach 60s on slow pods. 120s is still a reasonable safety net — if a normal single gen takes >60s, the backend's own 120s poll timeout will fire first anyway.

---

## Error Message Examples

| Source | Example message |
|--------|----------------|
| Backend: ComfyUI failure | "Comparison generation failed: Prompt submission failed 503: Service Unavailable" |
| Backend: timeout | "Comparison generation failed: Generation timed out after 120s" |
| Backend: no output | "Comparison generation completed but produced no image" |
| iOS: missing URL | "Server returned no comparison image URL" |
| iOS: download/decode fail | "Comparison download failed: The request timed out." |

---

## Execution Order
1. Backend: types → comfyui adapter → route (step 1)
2. iOS NetworkModule: request, response, APIClient (step 2)
3. iOS GenerationPipeline (step 3)
4. iOS AppCoordinator (step 4)
5. iOS AdvancedParametersPanel (step 5)
6. iOS DebugComparisonModal (step 6)
7. iOS ContentView + timeout (steps 7-8)

## Risks & Mitigations
- **Timeout:** Two sequential gens could approach the 60s iOS resource timeout. Mitigation: increase to 120s.
- **Second gen failure:** Backend catches errors, returns primary result + `comparisonError`. iOS shows alert.
- **Memory:** Four UIImages in ComparisonData. ~26MB total (4x 1280×1280 RGBA). Well within iPad RAM.

## Notes
- Generation time roughly doubles when comparison is on. Acceptable for a debug feature.
- Same seed guaranteed: cloned from the first workflow's configured KSampler seed.
- Toggle defaults to off — zero impact on normal usage.
- No changes to ResultModule.
