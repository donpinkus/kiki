import SwiftUI
import CanvasModule

struct LayerPanelView: View {
    @Environment(AppCoordinator.self) private var coordinator

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
