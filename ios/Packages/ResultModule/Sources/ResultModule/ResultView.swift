import SwiftUI

public struct ResultView: View {
    public init() {}

    public var body: some View {
        ZStack {
            Color(.systemGray6)

            VStack(spacing: 12) {
                Image(systemName: "photo.artframe")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Generated image will appear here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ResultView()
}
