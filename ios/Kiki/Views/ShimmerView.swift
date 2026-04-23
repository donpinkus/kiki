import SwiftUI

/// Animated linear-gradient sweep over a neutral fill. Used as a loading
/// placeholder for style-preview tiles.
struct ShimmerView: View {
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(.systemGray5))
            .overlay {
                ShimmerSweep()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
    }
}

private struct ShimmerSweep: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.55), location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.7)
            .offset(x: phase * geo.size.width * 2)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
        }
    }
}
