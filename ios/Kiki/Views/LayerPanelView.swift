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

    // Layer Options side menu (tap the already-selected row). All layer
    // actions live here — no swipe actions (removed 2026-08-23, Donald).
    @State private var optionsLayerId: UUID?
    @State private var showRenameAlert = false
    @State private var renameText = ""

    // Blend mode + layer opacity popover (tap the row's blend letter).
    @State private var blendLayerId: UUID?

    // Softer corner rounding for all layer-UI popovers — the default popover
    // radius visually clipped the first/last rows (Donald 2026-08-23).
    private static let popoverCornerRadius: CGFloat = 8

    private static let thumbnailSize: CGFloat = 52
    // Fixed row height: 52 thumbnail + 2×10 vertical padding, LazyVStack spacing 0.
    private static let rowHeight: CGFloat = 72
    private static let panelWidth: CGFloat = 320
    // Header: 28pt content (the + button) + 2×12 vertical padding + divider.
    private static let headerHeight: CGFloat = 53

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
        .presentationCornerRadius(Self.popoverCornerRadius)
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
        rowContent(layer: layer, index: index, isActive: isActive)
            .background(isActive ? Color.accentColor : Color(uiColor: .systemBackground))
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                if isActive {
                    // Procreate: tapping the selected layer opens Layer Options.
                    optionsLayerId = layer.id
                } else {
                    coordinator.canvasViewModel.selectLayer(at: index)
                }
            }
            .gesture(reorderGesture(layer: layer, index: index))
            .popover(isPresented: Binding(
                get: { optionsLayerId == layer.id },
                set: { if !$0 { optionsLayerId = nil } }
            ), arrowEdge: .trailing) {
                layerOptionsMenu(layer: layer, index: index)
                    .presentationCornerRadius(Self.popoverCornerRadius)
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

            // Blend mode letter (Procreate-style). Tap → blend mode + layer
            // opacity popover; shows the current mode's short code.
            Button {
                blendLayerId = layer.id
            } label: {
                Text(layer.blendMode.shortCode)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isActive ? .white.opacity(0.85) : .secondary)
                    .frame(minWidth: 24, minHeight: 24)
            }
            .buttonStyle(.plain)
            // Anchored here (not on the row) — a second .popover on the same
            // row view never fires; anchoring at the badge also points the
            // arrow at what was tapped.
            .popover(isPresented: Binding(
                get: { blendLayerId == layer.id },
                set: { if !$0 { blendLayerId = nil } }
            ), arrowEdge: .trailing) {
                blendModeMenu(layer: layer, index: index)
                    .presentationCornerRadius(Self.popoverCornerRadius)
            }

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

    // MARK: - Layer Options menu (tap the selected layer)

    /// One sectioned action list — iOS menu conventions: Title Case labels,
    /// toggles shown with trailing checkmarks, destructive action last in red,
    /// sections separated by grouped-background bands for scannability.
    private func layerOptionsMenu(layer: LayerInfo, index: Int) -> some View {
        let layerCount = coordinator.canvasViewModel.layers.count
        return VStack(alignment: .leading, spacing: 0) {
            // Section: rename (most common — its own group at the top)
            optionRow("Rename…", systemImage: "pencil") {
                optionsLayerId = nil
                renameText = layer.name
                showRenameAlert = true
            }

            sectionBreak()

            // Section: content operations
            optionRow("Select Contents", systemImage: "circle.dashed") {
                optionsLayerId = nil
                coordinator.selectLayerContents(at: index)
                coordinator.showLayerPanel = false
            }
            Divider()
            optionRow("Copy to Clipboard", systemImage: "doc.on.doc") {
                optionsLayerId = nil
                coordinator.copyLayer(at: index)
            }
            Divider()
            optionRow("Duplicate Layer", systemImage: "plus.square.on.square") {
                optionsLayerId = nil
                if coordinator.canvasViewModel.duplicateLayer(at: index) {
                    refreshThumbnails()
                }
            }
            .disabled(layerCount >= 16)
            Divider()
            optionRow("Clear Layer", systemImage: "xmark.circle") {
                optionsLayerId = nil
                coordinator.canvasViewModel.clearLayer(at: index)
                refreshThumbnails()
            }
            .disabled(layer.isLocked)

            sectionBreak()

            // Section: protection toggles
            optionRow("Lock", systemImage: layer.isLocked ? "lock.fill" : "lock",
                      isOn: layer.isLocked) {
                coordinator.canvasViewModel.setLayerLocked(!layer.isLocked, at: index)
                optionsLayerId = nil
            }
            Divider()
            optionRow("Alpha Lock", systemImage: "checkerboard.rectangle",
                      isOn: layer.isAlphaLocked) {
                coordinator.canvasViewModel.setLayerAlphaLocked(!layer.isAlphaLocked, at: index)
                optionsLayerId = nil
            }

            sectionBreak()

            // Section: destructive
            optionRow("Delete Layer", systemImage: "trash", role: .destructive) {
                optionsLayerId = nil
                if layerCount > 1 {
                    coordinator.canvasViewModel.deleteLayer(at: index)
                }
            }
            .disabled(layerCount <= 1)
        }
        .frame(width: 250)
    }

    // MARK: - Blend mode + opacity popover (tap the row's blend letter)

    /// Procreate-style: whole-layer opacity slider on top, then the blend mode
    /// list grouped darken / normal / lighten / contrast / difference, with
    /// the current mode highlighted and each mode's short code trailing.
    private func blendModeMenu(layer: LayerInfo, index: Int) -> some View {
        let groups: [[LayerBlendMode]] = [
            [.darken, .multiply, .colorBurn, .linearBurn],
            [.normal],
            [.lighten, .screen, .colorDodge, .add],
            [.overlay, .softLight, .hardLight],
            [.difference, .exclusion],
        ]
        return VStack(spacing: 0) {
            // Whole-layer opacity (live composite update; saves on release).
            VStack(spacing: 6) {
                HStack {
                    Text("Opacity")
                        .font(.subheadline)
                    Spacer()
                    Text(layer.opacity >= 0.995 ? "Max" : "\(Int((layer.opacity * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: {
                            let layers = coordinator.canvasViewModel.layers
                            return layers.indices.contains(index) ? layers[index].opacity : 1
                        },
                        set: { coordinator.canvasViewModel.setLayerOpacity($0, at: index) }
                    ),
                    in: 0...1
                ) { editing in
                    if !editing {
                        coordinator.canvasViewModel.commitLayerOpacity()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            sectionBreak()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                            if groupIndex > 0 {
                                sectionBreak()
                            }
                            ForEach(Array(group.enumerated()), id: \.element) { rowIndex, mode in
                                if rowIndex > 0 {
                                    Divider()
                                }
                                blendModeRow(mode, layer: layer, index: index)
                                    .id(mode)
                            }
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(layer.blendMode, anchor: .center)
                }
            }
        }
        .frame(width: 260, height: 560)
    }

    private func blendModeRow(_ mode: LayerBlendMode, layer: LayerInfo, index: Int) -> some View {
        let isSelected = layer.blendMode == mode
        return Button {
            coordinator.canvasViewModel.setLayerBlendMode(mode, at: index)
        } label: {
            HStack {
                Text(mode.displayName)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                Spacer()
                Text(mode.shortCode)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(minWidth: 26, minHeight: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? Color.white.opacity(0.25) : Color(uiColor: .secondarySystemBackground))
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? Color.accentColor : Color.clear)
    }

    /// Thick grouped-background band between menu sections (UIMenu-style).
    private func sectionBreak() -> some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemBackground))
            .frame(height: 6)
    }

    private func optionRow(_ title: String, systemImage: String, isOn: Bool = false,
                           role: ButtonRole? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
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
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}
