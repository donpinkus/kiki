import SwiftUI
import CanvasModule

struct LayerPanelView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var thumbnails: [UUID: UIImage] = [:]

    private static let thumbnailSize: CGFloat = 36

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
                        layerRow(layer: layer, index: index, isActive: index == activeIndex)
                    }
                }
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
    }
}
