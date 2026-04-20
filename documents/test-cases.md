# Test Cases

High-level UX expectations for the app. Each test describes what the user should experience — not implementation details. If any of these break, it's a regression.

Last updated: 2026-04-19

---

## App Launch & Connection

1. **Cold start provisioning.** User opens the app for the first time (or after a long idle). On the drawing canvas page, the 'generated image' pane shows a warm-up progress bar with status messages (e.g. "Reserving GPU...", "Pulling container image...", "Loading AI model..."). The user can start drawing immediately — the canvas is fully responsive during provisioning. Once the pod is ready, the first generated image appears automatically without any user action.

2. **Warm reconnection.** User closes and reopens the app within 10 minutes. The existing pod is reused — no provisioning delay. Generation resumes immediately.

3. **Gallery pre-warming.** When the user is on the gallery page, the GPU pod is already provisioning in the background. By the time they tap into a drawing, the pod may already be ready.

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

14. **Streaming badge.** While actively receiving generated frames, a "LIVE" badge with frame count appears in the top-right corner of the result pane.

15. **Error toast.** If generation fails, a non-blocking error toast appears at the bottom of the result pane. It auto-dismisses after 10 seconds. The last successful image remains visible behind it.

---

## Gallery & Persistence

16. **Auto-save.** Changes to the canvas and prompt are saved automatically within ~1 second. Closing the app and reopening preserves the drawing exactly as it was.

17. **Gallery thumbnails.** The gallery shows up-to-date thumbnails for each drawing. Thumbnails reflect the current canvas content.

18. **Empty drawing cleanup.** If the user creates a new drawing and navigates back to the gallery without drawing anything, the empty drawing is automatically deleted.

19. **Drawing load.** Tapping a drawing in the gallery loads it with all layers, the correct prompt, and the last generated image (if any).

---

## Reliability & Edge Cases

20. **Pod spot preemption.** If the GPU pod is reclaimed by RunPod (spot preemption), the backend transparently replaces it with a new pod. The user may see a brief interruption in generation but the app does not crash, freeze, or show a permanent error. Generation resumes automatically.

21. **Pod provisioning failure.** If pod provisioning fails (no GPU capacity, container pull timeout, etc.), the app retries automatically with exponential backoff. The user sees provisioning status messages during retry, not a dead "Connecting..." state.

22. **Idle timeout.** If the user leaves the app idle for more than 10 minutes, the pod is terminated to save cost. When the user returns and starts drawing, a new pod is provisioned automatically. The user sees the warm-up progress bar again.

23. **App background/foreground.** Backgrounding the app stops the stream cleanly. Foregrounding resumes it — reusing the existing pod if within the 10-minute idle window, or provisioning a new one if not.

24. **Network interruption.** If the network drops briefly during drawing, the app reconnects automatically (up to 5 attempts with backoff). The pod stays alive during the interruption. Once reconnected, generation resumes from the current canvas state.

25. **Backend redeploy.** If the Railway backend redeploys while the user is connected, the WebSocket drops and the app reconnects to the new backend instance. The existing pod is reused if still alive.
