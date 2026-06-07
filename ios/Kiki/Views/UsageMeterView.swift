import SwiftUI

/// Compact, tappable free-tier usage meter. A little bar that fills as the user
/// spends toward the monthly $10 fal cap; tapping opens the paywall. Renders
/// nothing for exempt users (test accounts / active subscribers) or until usage
/// has loaded — see `AppCoordinator.showUsageBar`.
struct UsageMeterView: View {
    @Environment(AppCoordinator.self) private var coordinator

    private let barWidth: CGFloat = 84

    var body: some View {
        if coordinator.showUsageBar {
            Button {
                coordinator.showPaywall = true
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel(labelText)
        }
    }

    private var fraction: Double { coordinator.usageFraction }

    private var fillColor: Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }

    private var labelText: String {
        if fraction >= 1 { return "Out of free drawing — Subscribe" }
        let remaining = max((coordinator.usageCapUsd ?? 0) - (coordinator.usageSpendUsd ?? 0), 0)
        return String(format: "$%.2f free drawing left", remaining)
    }

    private var content: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                    .frame(width: barWidth, height: 6)
                Capsule().fill(fillColor)
                    .frame(width: max(4, barWidth * fraction), height: 6)
            }
            .animation(.easeOut(duration: 0.3), value: fraction)

            Text(labelText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(fraction >= 1 ? Color.red : .secondary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
