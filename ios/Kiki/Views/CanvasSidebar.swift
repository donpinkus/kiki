import SwiftUI
import CanvasModule

struct CanvasSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isDraggingSize = false

    private let widthRange = BrushConfig.widthRange

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 12) {
            // Vertical size slider
            VerticalSizeSlider(value: $coordinator.toolSize, range: widthRange) { editing in
                isDraggingSize = editing
            }
            .frame(width: 30, height: 180)
            .overlay(alignment: .trailing) {
                if isDraggingSize {
                    // Show the configured size at rest (force=1, perp tilt) so the
                    // preview matches the actual stamp diameter the user will get.
                    let displaySize = max(coordinator.toolSize, 4)
                    let containerSize = max(displaySize + 16, 32)
                    VStack(spacing: 4) {
                        Text("Size \(Int(coordinator.toolSize))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Circle()
                            .stroke(.primary, lineWidth: 1)
                            .frame(width: displaySize, height: displaySize)
                            .frame(width: containerSize, height: containerSize)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .offset(x: containerSize / 2 + 28)
                }
            }

            Divider().frame(width: 24)

            // All brush settings live in the full-page Brush Studio (fullScreenCover owned
            // by DrawingView); the sidebar keeps only Size for mid-drawing tweaks. Brush
            // tool only.
            Button {
                coordinator.showBrushStudio = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(coordinator.currentTool == .brush ? .primary : .tertiary)
                    .frame(width: 36, height: 36)
            }
            .tint(Color.primary)
            .disabled(coordinator.currentTool != .brush)

            Divider().frame(width: 24)

            actionButton(
                icon: "arrow.uturn.backward",
                action: coordinator.undo,
                // Select-active undo steps back through selection edits even
                // when the canvas itself has no undo history yet.
                disabled: !coordinator.canvasViewModel.canUndo
                    && !(coordinator.currentTool == .select
                         && coordinator.canvasViewModel.selection.canUndoStep)
            )
            actionButton(
                icon: "arrow.uturn.forward",
                action: coordinator.redo,
                disabled: !coordinator.canvasViewModel.canRedo
            )

            // Paste the copied selection (appears once something was copied).
            // Pasted content floats for placement; the paste bar commits it.
            if coordinator.canPasteSelection {
                Divider().frame(width: 24)
                actionButton(
                    icon: "doc.on.clipboard",
                    action: coordinator.pasteSelection,
                    disabled: false
                )
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(
            KikiTheme.sidebarBackground,
            in: UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 16, topTrailing: 16)
            )
        )
        .shadow(color: .black.opacity(0.25), radius: 8, x: 2, y: 0)
        // Procreate-style chrome is always dark (matches DrawingTopBar).
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Helpers

    private func actionButton(icon: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 36, height: 36)
        }
        .tint(Color.primary)
        .disabled(disabled)
    }
}

/// Vertical brush-size slider with a logarithmic scale and absolute tracking.
///
/// - Logarithmic: brush size is perceived multiplicatively (3→4 px is a big jump, 80→81 is
///   invisible), so equal finger travel maps to equal *ratio* change. The bottom half of the
///   track covers the small sizes finely instead of racing through them.
/// - Absolute tracking: the thumb jumps to the touch on press and follows the finger — the
///   whole strip is touchable, no need to land on the thumb.
private struct VerticalSizeSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let onEditingChanged: (Bool) -> Void

    @State private var isEditing = false

    private var logMin: CGFloat { log(range.lowerBound) }
    private var logMax: CGFloat { log(range.upperBound) }

    private func t(for size: CGFloat) -> CGFloat {
        (log(min(max(size, range.lowerBound), range.upperBound)) - logMin) / (logMax - logMin)
    }

    private func size(at t: CGFloat) -> CGFloat {
        exp(logMin + min(max(t, 0), 1) * (logMax - logMin))
    }

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let trackWidth: CGFloat = 6
            let thumbSize: CGFloat = 24
            let currentT = t(for: value)
            // Thumb center travels [thumbSize/2, height - thumbSize/2]; top = max.
            let thumbY = (height - thumbSize) * (1 - currentT) + thumbSize / 2

            ZStack(alignment: .top) {
                Capsule()
                    .fill(KikiTheme.sliderTrack)
                    .frame(width: trackWidth)
                Capsule()
                    .fill(KikiTheme.sliderFill)
                    .frame(width: trackWidth, height: max(height - thumbY, trackWidth))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Circle()
                    // Fixed white in both modes (like the system slider knob) so it stands
                    // out against the dark sidebar material; shadow separates it in light mode.
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        let t = 1 - (gesture.location.y - thumbSize / 2) / max(height - thumbSize, 1)
                        value = size(at: t)
                    }
                    .onEnded { _ in
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
        }
    }
}
