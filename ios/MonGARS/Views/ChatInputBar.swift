import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    let isGenerating: Bool
    let isListening: Bool
    let audioLevel: Float
    let onSend: () -> Void
    let onVoiceToggle: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            if isListening {
                listeningIndicator
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    onVoiceToggle()
                } label: {
                    Image(systemName: isListening ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(isListening ? Color.red : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                        .scaleEffect(isListening ? 1.0 + CGFloat(audioLevel) * 0.15 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: audioLevel)
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: isListening)
                .accessibilityLabel(isListening ? "Stop listening" : "Start voice input")

                TextField("Message...", text: $text, axis: .vertical)
                    .focused($isFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 20))
                    .submitLabel(.send)
                    .onSubmit {
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onSend()
                        }
                    }

                if isGenerating {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.red)
                    }
                    .sensoryFeedback(.impact(weight: .heavy), trigger: isGenerating)
                    .accessibilityLabel("Stop generating")
                } else {
                    Button {
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(canSend ? Color.accentColor : Color(.tertiaryLabel))
                    }
                    .disabled(!canSend)
                    .sensoryFeedback(.impact(weight: .light), trigger: text.isEmpty)
                    .accessibilityLabel("Send message")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .animation(.spring(duration: 0.25), value: isListening)
    }

    private var listeningIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text("Listening...")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }
}
