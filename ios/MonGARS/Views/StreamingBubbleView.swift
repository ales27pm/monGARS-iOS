import SwiftUI

struct StreamingBubbleView: View {
    let content: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 4) {
                if content.isEmpty {
                    TypingIndicator()
                } else {
                    Text(content)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: .rect(
                                topLeadingRadius: 4,
                                bottomLeadingRadius: 18,
                                bottomTrailingRadius: 18,
                                topTrailingRadius: 18
                            )
                        )
                }

                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Generating...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}

struct TypingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 8, height: 8)
                    .scaleEffect(phase == index ? 1.2 : 0.8)
                    .opacity(phase == index ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: .rect(
                topLeadingRadius: 4,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 18,
                topTrailingRadius: 18
            )
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }
}
