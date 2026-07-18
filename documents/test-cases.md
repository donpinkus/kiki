# Test Cases

High-level UX expectations for the app. Each test describes what the user should experience — not implementation details. If any of these break, it's a regression.

Last updated: 2026-07-18 (rewritten for the fal + Lambda H100 provider architecture; pod-provisioning-era tests replaced)

---

## App Launch & Connection

1. **Cold start.** User opens the app for the first time (or after a long idle). Entering a drawing starts the stream automatically; while the image provider warms up, the result pane shows an honest connecting/warm-up state — never a blank pane or silent dead state. The user can start drawing immediately — the canvas is fully responsive during warm-up. Once the provider is ready, the first generated image appears automatically without any user action.

2. **Warm reconnection.** User closes and reopens the app shortly after. Generation resumes quickly with no cold-start wait (the fal keep-warm pinger and/or a running H100 pool instance keep the first stroke fast).

3. **AI readiness visibility.** The "Kiki's AI" status badge shows ambient H100-pool readiness, with a detail popover. When the pool is asleep, the badge shows a distinct "asleep" state with a **Wake up** action that starts pool warm-up before the user commits to drawing.

---

## Canvas & Generation

4. **Real-time generation while drawing.** As the user makes any changes to the canvas (draw, erase, lasso, move lasso selection, undo, redo, clear), new generations appear in real-time on the right pane. Generations are sent while the user is actively changing things — NOT waiting for the user to complete an action (e.g., lift their pen).

5. **Prompt and style changes.** When the user changes the text prompt or selects a different style, the current sketch is re-generated with the new prompt immediately, even if the canvas hasn't changed.

6. **Idle canvas.** When the user stops drawing, the last generated image stays visible on the right pane. No flickering, no blank state, no re-generation of the same sketch.

7. **Empty canvas.** Before the user draws anything, the right pane shows a placeholder message ("Start drawing to see your image come to life"). No generation attempts are made.

8. **Eraser works on loaded drawings.** After loading a drawing from the gallery, the eraser tool works immediately without any issues.

9. **Lasso persists across tools.** After drawing a lasso selection, switching to the pen or eraser tool does not clear the lasso. The selection stays visible with marching ants. Only the explicit "Clear Lasso" button removes it.

10. **Lasso content generates normally.** Content inside a lasso selection is treated as a normal part of the image for generation. The generated result includes the selected content in its current position.

11. **Lasso drag generates in real-time.** When dragging lasso-selected content to a new position, the generation updates in real-time showing the content at its current dragged position — same live behavior as drawing.

12. **Layer operations.** Adding, deleting, reordering, and toggling layer visibility all trigger new generations reflecting the change.

---

## Result Pane

13. **Never blank after first image.** Once the first successful generated image appears, the right pane never shows a blank/empty state — even during errors, reconnections, or provisioning. The last successful image stays visible.

14. **Result layouts.** Settings → Display toggles between **Overlay** (the default — generated image locked opaque exactly on top of the canvas, transforming with it; fresh strokes flash on a visual-only surface and clear on each returned frame), **Split** (fixed result pane on the left half), and **Fullscreen** (the result floats as an image-only panel over the canvas). The choice persists across launches.

15. **Error toast.** If generation fails, a non-blocking error toast appears at the bottom of the result pane. It auto-dismisses after 10 seconds. The last successful image remains visible behind it.

---

## Gallery & Persistence

16. **Auto-save.** Changes to the canvas and prompt are saved automatically within ~1 second. Closing the app and reopening preserves the drawing exactly as it was.

17. **Gallery thumbnails.** The gallery shows up-to-date thumbnails for each drawing. Thumbnails reflect the current canvas content.

18. **Empty drawing cleanup.** If the user creates a new drawing and navigates back to the gallery without drawing anything, the empty drawing is automatically deleted.

19. **Drawing load.** Tapping a drawing in the gallery loads it with all layers, the correct prompt, and the last generated image (if any).

---

## Reliability & Edge Cases

20. **Upstream drop mid-session.** If the image provider connection drops mid-session (fal pool churn, network blip), the backend reconnects transparently. The user may see a brief interruption in generation but the app does not crash, freeze, or show a permanent error. Generation resumes automatically.

21. **Provider failure mid-session.** If an H100 pool instance dies mid-session (auto mode), the session degrades to fal transparently — frames keep flowing. The user never lands in a dead "Connecting..." state; explicit `?imageProvider=` test-account overrides never silently switch provider.

22. **Idle timeout.** Idle costs are bounded invisibly: the fal socket closes shortly after the last frame and reopens on the next stroke, and idle H100 pool instances scale down after ~30 minutes. A user returning after a long idle can draw immediately and generation resumes automatically (possibly served by fal while the pool warms).

23. **App background/foreground.** Backgrounding the app stops the stream cleanly. Foregrounding resumes it automatically — the user just keeps drawing; at most a brief warm-up state appears.

24. **Network interruption.** If the network drops briefly during drawing, the app reconnects automatically (up to 5 attempts with backoff). Once reconnected, generation resumes from the current canvas state.

25. **Backend redeploy.** If the Railway backend redeploys while the user is connected, the WebSocket drops and the app reconnects to the new backend instance. Generation resumes on a fresh provider session.

---

## Fullscreen Result Panel

26. **Always visible, image-sized.** In fullscreen, the generated image floats as a panel sized to the image (rounded corners + drop shadow, no buttons or glass backing). It is always visible — never auto-hidden and there is no close button.

27. **Canvas fills the pane.** In fullscreen the drawing surface fills the available height below the toolbar (a large square), not a small centered square.

28. **Draw through the panel.** A single finger or Apple Pencil that touches the panel draws on the canvas underneath — the panel never intercepts single-touch drawing. A stroke begun on the canvas keeps drawing as it passes over the panel.

29. **Two-finger move/scale.** Two fingers starting on the panel move it; pinch scales it (aspect-locked, no rotation). Two fingers on the canvas still pan/zoom/rotate the canvas as usual.

30. **Transparency hole.** While drawing, the panel becomes see-through in a soft circle around the pencil so the canvas is visible underneath; the hole follows the pencil and fades closed shortly after lifting. (Hover-driven hole requires M2+ iPad Pro hardware and is not currently shipped.)
