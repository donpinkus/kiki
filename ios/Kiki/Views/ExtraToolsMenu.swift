import SwiftUI

/// The "More tools" dropdown in `DrawingTopBar`: the less-frequent AI/reference
/// tools (posable figure, object library, AI Edit) live here so the bar keeps
/// only the everyday tools as bare icons. Each row is a name + one-line
/// description, because an icon alone doesn't explain what "figure.stand" or
/// "shippingbox" will do to your drawing.
///
/// Selection closes the popover FIRST and reports the choice via `onSelect`,
/// which the bar fires once the popover has actually gone — presenting a
/// second popover/sheet while this one is still animating out is dropped
/// silently by UIKit.
struct ExtraToolsMenu: View {
    enum Tool: CaseIterable, Identifiable {
        case figure, objects, aiEdit
        var id: Self { self }

        var icon: String {
            switch self {
            case .figure: "figure.stand"
            case .objects: "shippingbox"
            case .aiEdit: "sparkles"
            }
        }

        var title: String {
            switch self {
            case .figure: "Pose Figure"
            case .objects: "Objects"
            case .aiEdit: "AI Edit"
            }
        }

        var subtitle: String {
            switch self {
            case .figure: "Place a posable 3D mannequin to draw over. It's a reference — Kiki won't see it."
            case .objects: "Your saved cutouts. Drop one into this drawing or pin it as a reference."
            case .aiEdit: "Describe a change and Kiki repaints the selection, or the whole drawing."
            }
        }
    }

    /// Rows that can't act right now (e.g. AI Edit while posing) render dimmed.
    let isEnabled: (Tool) -> Bool
    /// Unread count shown on the Objects row (background 3D lifts that finished).
    let objectsBadge: Int
    let onSelect: (Tool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Tool.allCases) { tool in
                row(tool)
                if tool != Tool.allCases.last {
                    Divider().padding(.leading, 62)
                }
            }
        }
        .frame(width: 320)
        .padding(.vertical, 6)
        .presentationCompactAdaptation(.popover)
        .presentationCornerRadius(12)
    }

    private func row(_ tool: Tool) -> some View {
        let enabled = isEnabled(tool)
        return Button {
            onSelect(tool)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tool.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tool.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if tool == .objects, objectsBadge > 0 {
                            Text("\(objectsBadge) new")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red, in: Capsule())
                        }
                    }
                    Text(tool.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
