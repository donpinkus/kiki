import SwiftUI
import CanvasModule

struct LayerPanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var thumbnails: [UUID: UIImage] = [:]

    // Drag-to-reorder state. The dragged row is tracked by its stable id so it
    // keeps identity while the underlying `layers` array reorders live.
    @State private var draggingId: UUID?
    @State private var dragStartModelIndex: Int?
    @State private var dragTranslation: CGFloat = 0

    private static let thumbnailSize: CGFloat = 36
    // Fixed row height: 36 thumbnail + 2×10 vertical padding, LazyVStack spacing 0.
    private static let rowHeight: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Button {
                    coordinator.canvasViewModel.addLayer()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .disabled(coordinator.canvasViewModel.layers.count >= 16)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Layer list (top = highest layer = drawn last)
            ScrollView {
                LazyVStack(spacing: 0) {
                    let layers = coordinator.canvasViewModel.layers
                    let activeIndex = coordinator.canvasViewModel.activeLayerIndex
                    ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, layer in
                        let isDragging = layer.id == draggingId
                        layerRow(layer: layer, index: index, isActive: index == activeIndex)
                            .offset(y: dragOffset(for: layer))
                            .scaleEffect(isDragging ? 1.03 : 1)
                            .shadow(color: .black.opacity(isDragging ? 0.25 : 0),
                                    radius: isDragging ? 8 : 0, x: 0, y: isDragging ? 4 : 0)
                            .zIndex(isDragging ? 1 : 0)
                            // Keep the picked-up row instant (its offset already
                            // tracks the finger); only the other rows animate.
                            .transaction { txn in
                                if isDragging { txn.animation = nil }
                            }
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85),
                           value: coordinator.canvasViewModel.layers.map(\.id))
            }
        }
        .onAppear { refreshThumbnails() }
    }

    private func refreshThumbnails() {
        let layers = coordinator.canvasViewModel.layers
        let scale = UIScreen.main.scale
        let pixelSize = Self.thumbnailSize * scale
        var next: [UUID: UIImage] = [:]
        for (index, layer) in layers.enumerated() {
            if let thumb = coordinator.canvasViewModel.layerThumbnail(at: index, maxDimension: pixelSize) {
                next[layer.id] = thumb
            }
        }
        thumbnails = next
    }

    // MARK: - Drag-to-reorder

    /// Offset that keeps the picked-up row under the finger even as the live
    /// `moveLayer` calls shift its natural slot by whole rows.
    private func dragOffset(for layer: LayerInfo) -> CGFloat {
        guard layer.id == draggingId, let start = dragStartModelIndex else { return 0 }
        let layers = coordinator.canvasViewModel.layers
        guard let current = layers.firstIndex(where: { $0.id == layer.id }) else { return 0 }
        return dragTranslation - CGFloat(start - current) * Self.rowHeight
    }

    /// Long-press to pick up, then drag to reorder. Each time the finger crosses
    /// a neighbor's midpoint we commit the move, so the canvas re-stacks live.
    private func reorderGesture(layer: LayerInfo, index: Int) -> some Gesture {
        // `.global` coordinate space is load-bearing (same fix as the floating
        // result panel, commit cfad75b): the dragged row is moved by `.offset(...)`
        // and its slot shifts as `moveLayer` reorders the list, so a default
        // `.local` DragGesture measures translation relative to the row it's itself
        // moving — the offset feeds back into the next reading and the row flickers.
        // `.global` measures the raw finger delta, immune to the row's own movement.
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if draggingId != layer.id {
                    // Pick up (fires on long-press completion, before any move).
                    draggingId = layer.id
                    dragStartModelIndex = index
                    dragTranslation = 0
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                if let drag {
                    dragTranslation = drag.translation.height
                    commitLiveReorder()
                }
            }
            .onEnded { _ in endDrag() }
    }

    private func commitLiveReorder() {
        guard let id = draggingId, let start = dragStartModelIndex else { return }
        let layers = coordinator.canvasViewModel.layers
        guard let current = layers.firstIndex(where: { $0.id == id }) else { return }
        // Finger down (positive translation) → lower in the panel → lower model index.
        let steps = Int((dragTranslation / Self.rowHeight).rounded())
        let target = max(0, min(layers.count - 1, start - steps))
        if target != current {
            coordinator.canvasViewModel.moveLayer(from: current, to: target)
        }
    }

    private func endDrag() {
        guard draggingId != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            draggingId = nil
            dragStartModelIndex = nil
            dragTranslation = 0
        }
        coordinator.saveCurrentDrawing()
    }

    // MARK: - Row

    private func layerRow(layer: LayerInfo, index: Int, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            // Visibility toggle
            Button {
                coordinator.canvasViewModel.toggleLayerVisibility(at: index)
            } label: {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(isActive ? .white : (layer.isVisible ? .primary : .secondary))
                    .frame(width: 24, height: 24)
            }

            // Thumbnail preview of layer contents
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white)
                if let thumb = thumbnails[layer.id] {
                    Image(uiImage: thumb)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4), lineWidth: 0.5))

            // Layer name
            Text(layer.name)
                .font(.subheadline.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .white : (layer.isVisible ? .primary : .secondary))

            Spacer()

            // Delete button (only if more than 1 layer)
            if coordinator.canvasViewModel.layers.count > 1 {
                Button {
                    coordinator.canvasViewModel.deleteLayer(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isActive ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            coordinator.canvasViewModel.selectLayer(at: index)
        }
        .gesture(reorderGesture(layer: layer, index: index))
    }
}
