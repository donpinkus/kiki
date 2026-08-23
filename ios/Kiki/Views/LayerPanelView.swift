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

    // Swipe-left quick actions (Procreate: Lock / Duplicate / Delete).
    // One row revealed at a time; `swipeTranslation` tracks the live drag.
    @State private var revealedId: UUID?
    @State private var swipeTranslation: CGFloat = 0

    // Layer Options side menu (tap the already-selected row).
    @State private var optionsLayerId: UUID?
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private static let thumbnailSize: CGFloat = 52
    // Fixed row height: 52 thumbnail + 2×10 vertical padding, LazyVStack spacing 0.
    private static let rowHeight: CGFloat = 72
    private static let panelWidth: CGFloat = 320
    // Header: 28pt content (the + button) + 2×12 vertical padding + divider.
    private static let headerHeight: CGFloat = 53
    // Total width of the three revealed swipe-action buttons.
    private static let swipeActionsWidth: CGFloat = 186

    /// Panel grows with the layer count so every row is visible without
    /// scrolling; once it would exceed what fits on screen (minus room for the
    /// top bar + popover arrow) it caps and the ScrollView takes over.
    private var panelHeight: CGFloat {
        let rows = CGFloat(coordinator.canvasViewModel.layers.count)
        let content = Self.headerHeight + rows * Self.rowHeight
        let maxHeight = UIScreen.main.bounds.height - 160
        return min(content, maxHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Button {
                    coordinator.canvasViewModel.addLayer()
                    refreshThumbnails()
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
        .frame(width: Self.panelWidth, height: panelHeight)
        .onAppear { refreshThumbnails() }
        .onChange(of: coordinator.canvasViewModel.layers.count) {
            refreshThumbnails()
        }
        .alert("Rename Layer", isPresented: $showRenameAlert) {
            TextField("Layer name", text: $renameText)
            Button("Rename") {
                let index = coordinator.canvasViewModel.activeLayerIndex
                coordinator.canvasViewModel.renameLayer(at: index, to: renameText)
            }
            Button("Cancel", role: .cancel) {}
        }
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
                    closeSwipe()
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

    // MARK: - Swipe-left quick actions

    /// Live horizontal offset for a row's content: the in-flight drag plus the
    /// resting position (revealed rows park at -swipeActionsWidth).
    private func swipeOffset(for layer: LayerInfo) -> CGFloat {
        let resting: CGFloat = revealedId == layer.id ? -Self.swipeActionsWidth : 0
        guard swipingId == layer.id else { return resting }
        return min(0, max(-Self.swipeActionsWidth - 24, resting + swipeTranslation))
    }

    @State private var swipingId: UUID?

    private func swipeGesture(layer: LayerInfo) -> some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                // Horizontal-dominant drags only — vertical belongs to the
                // ScrollView, and the reorder long-press has its own path.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                guard draggingId == nil else { return }
                swipingId = layer.id
                swipeTranslation = value.translation.width
            }
            .onEnded { value in
                guard swipingId == layer.id else { return }
                swipingId = nil
                swipeTranslation = 0
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                    if value.predictedEndTranslation.width < -Self.swipeActionsWidth / 2 {
                        revealedId = layer.id
                    } else if value.translation.width > 20 {
                        revealedId = nil
                    } else if revealedId == layer.id, value.translation.width > -20 {
                        revealedId = nil
                    }
                }
            }
    }

    private func closeSwipe() {
        guard revealedId != nil || swipingId != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            revealedId = nil
            swipingId = nil
            swipeTranslation = 0
        }
    }

    // MARK: - Row

    private func layerRow(layer: LayerInfo, index: Int, isActive: Bool) -> some View {
        ZStack(alignment: .trailing) {
            // Quick actions revealed behind the row content on swipe-left.
            swipeActions(layer: layer, index: index)

            // Opaque background always (matches the popover chrome) so the
            // swipe actions behind the row stay hidden until revealed.
            rowContent(layer: layer, index: index, isActive: isActive)
                .background(isActive ? Color.accentColor : Color(uiColor: .systemBackground))
                .offset(x: swipeOffset(for: layer))
        }
        .frame(height: Self.rowHeight)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            if revealedId != nil || swipingId != nil {
                closeSwipe()
            } else if isActive {
                // Procreate: tapping the selected layer opens Layer Options.
                optionsLayerId = layer.id
            } else {
                coordinator.canvasViewModel.selectLayer(at: index)
            }
        }
        .gesture(swipeGesture(layer: layer))
        .gesture(reorderGesture(layer: layer, index: index))
        .popover(isPresented: Binding(
            get: { optionsLayerId == layer.id },
            set: { if !$0 { optionsLayerId = nil } }
        ), arrowEdge: .trailing) {
            layerOptionsMenu(layer: layer, index: index)
        }
    }

    private func rowContent(layer: LayerInfo, index: Int, isActive: Bool) -> some View {
        HStack(spacing: 12) {
            // Thumbnail preview of layer contents
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white)
                if let thumb = thumbnails[layer.id] {
                    Image(uiImage: thumb)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4), lineWidth: 0.5))

            // Layer name + status badges
            HStack(spacing: 6) {
                Text(layer.name)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : (layer.isVisible ? .primary : .secondary))
                    .lineLimit(1)
                if layer.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? .white.opacity(0.85) : .secondary)
                }
                if layer.isAlphaLocked {
                    Image(systemName: "checkerboard.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? .white.opacity(0.85) : .secondary)
                }
            }

            Spacer(minLength: 8)

            // Blend mode letter (Procreate's "N" = Normal). Display-only until
            // per-layer blend modes exist in the engine.
            Text("N")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isActive ? .white.opacity(0.85) : .secondary)
                .frame(width: 24, height: 24)

            // Visibility toggle (kept as the eye, not Procreate's checkbox)
            Button {
                coordinator.canvasViewModel.toggleLayerVisibility(at: index)
            } label: {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 15))
                    .foregroundStyle(isActive ? .white : (layer.isVisible ? .primary : .secondary))
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func swipeActions(layer: LayerInfo, index: Int) -> some View {
        HStack(spacing: 0) {
            swipeActionButton(
                title: layer.isLocked ? "Unlock" : "Lock",
                systemImage: layer.isLocked ? "lock.open" : "lock",
                color: .blue
            ) {
                coordinator.canvasViewModel.setLayerLocked(!layer.isLocked, at: index)
                closeSwipe()
            }
            swipeActionButton(title: "Duplicate", systemImage: "plus.square.on.square", color: .indigo) {
                if coordinator.canvasViewModel.duplicateLayer(at: index) {
                    refreshThumbnails()
                }
                closeSwipe()
            }
            swipeActionButton(title: "Delete", systemImage: "trash", color: .red) {
                closeSwipe()
                if coordinator.canvasViewModel.layers.count > 1 {
                    coordinator.canvasViewModel.deleteLayer(at: index)
                }
            }
            .disabled(coordinator.canvasViewModel.layers.count <= 1)
        }
        .frame(width: Self.swipeActionsWidth, height: Self.rowHeight)
    }

    private func swipeActionButton(title: String, systemImage: String, color: Color,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: Self.swipeActionsWidth / 3, height: Self.rowHeight)
            .background(color)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layer Options menu (tap the selected layer)

    private func layerOptionsMenu(layer: LayerInfo, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            optionRow("Rename", systemImage: "pencil") {
                optionsLayerId = nil
                renameText = layer.name
                showRenameAlert = true
            }
            Divider()
            optionRow("Select", systemImage: "circle.dashed") {
                optionsLayerId = nil
                coordinator.selectLayerContents(at: index)
                coordinator.showLayerPanel = false
            }
            Divider()
            optionRow("Copy", systemImage: "doc.on.doc") {
                optionsLayerId = nil
                coordinator.copyLayer(at: index)
            }
            Divider()
            optionRow("Duplicate", systemImage: "plus.square.on.square") {
                optionsLayerId = nil
                if coordinator.canvasViewModel.duplicateLayer(at: index) {
                    refreshThumbnails()
                }
            }
            .disabled(coordinator.canvasViewModel.layers.count >= 16)
            Divider()
            optionRow("Clear", systemImage: "xmark.circle") {
                optionsLayerId = nil
                coordinator.canvasViewModel.clearLayer(at: index)
                refreshThumbnails()
            }
            .disabled(layer.isLocked)
            Divider()
            optionRow("Alpha Lock", systemImage: "checkerboard.rectangle",
                      isOn: layer.isAlphaLocked) {
                coordinator.canvasViewModel.setLayerAlphaLocked(!layer.isAlphaLocked, at: index)
                optionsLayerId = nil
            }
        }
        .frame(width: 220)
    }

    private func optionRow(_ title: String, systemImage: String, isOn: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
