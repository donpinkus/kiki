import SwiftUI
import CanvasModule

struct DrawingTopBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showAdvancedParameters = false

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(spacing: 12) {
            // MARK: Left — Gallery
            Button {
                coordinator.navigateToGallery()
            } label: {
                Label("Gallery", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
            }

            Spacer()

            // MARK: Center — Style, Prompt, Stream Status, Settings
            Button {
                coordinator.showStylePicker = true
            } label: {
                Text(coordinator.selectedStyle.name)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            TextField("Describe what you want…", text: $coordinator.promptText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .frame(minWidth: 120, maxWidth: 400)

            streamActionButton

            Button {
                showAdvancedParameters = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .popover(isPresented: $showAdvancedParameters) {
                AdvancedParametersPanel()
                    .frame(width: 400, height: 600)
            }

            Button {
                coordinator.drawingLayout = coordinator.drawingLayout == .splitScreen
                    ? .fullscreen : .splitScreen
            } label: {
                Image(systemName: coordinator.drawingLayout == .splitScreen
                    ? "rectangle.inset.filled" : "rectangle.split.2x1")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }

            Spacer()

            // MARK: Right — Pen, Eraser, Reset Transform
            toolButton(icon: "pencil.tip", tool: .brush)
            toolButton(icon: "eraser", tool: .eraser)

            if !coordinator.canvasViewModel.isDefaultTransform {
                actionButton(
                    icon: "arrow.counterclockwise",
                    action: coordinator.canvasViewModel.resetViewTransform,
                    disabled: false
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Stream Action Button

    private var streamActionButton: some View {
        Group {
            if coordinator.streamHasPendingUpdate {
                Button {
                    coordinator.applyStreamUpdate()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Update")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: Capsule())
                }
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(streamStatusColor)
                        .frame(width: 8, height: 8)
                    Text(streamStatusLabel)
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private var streamStatusColor: Color {
        switch coordinator.streamConnectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    private var streamStatusLabel: String {
        switch coordinator.streamConnectionState {
        case .connected: return "Streaming"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        }
    }

    // MARK: - Helpers

    private func toolButton(icon: String, tool: DrawingTool) -> some View {
        Button {
            coordinator.currentTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(coordinator.currentTool == tool ? Color.accentColor : .primary)
                .frame(width: 36, height: 36)
        }
    }

    private func actionButton(icon: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 36, height: 36)
        }
        .disabled(disabled)
    }
}
