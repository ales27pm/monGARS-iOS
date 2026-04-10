import SwiftUI
import SwiftData

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    let existingConversation: Conversation?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            messagesArea

            if viewModel.isGenerating {
                StreamingBubbleView(content: viewModel.streamingContent)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ChatInputBar(
                text: $viewModel.inputText,
                isGenerating: viewModel.isGenerating,
                isListening: viewModel.speechRecognizer.isListening,
                audioLevel: viewModel.speechRecognizer.audioLevel,
                onSend: {
                    if viewModel.speechRecognizer.isListening {
                        viewModel.speechRecognizer.stopListening()
                        viewModel.sendVoiceInput()
                    } else {
                        viewModel.sendMessage()
                    }
                },
                onVoiceToggle: {
                    if viewModel.speechRecognizer.isListening {
                        viewModel.speechRecognizer.stopListening()
                        if !viewModel.speechRecognizer.transcribedText.isEmpty {
                            viewModel.inputText = viewModel.speechRecognizer.transcribedText
                        }
                    } else {
                        viewModel.speechRecognizer.startListening(
                            language: viewModel.localeManager.currentLanguage
                        )
                    }
                },
                onCancel: {
                    viewModel.cancelGeneration()
                }
            )
        }
        .navigationTitle(viewModel.conversation?.displayTitle ?? "monGARS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let last = viewModel.messages.last(where: { $0.isAssistant }) {
                        Button("Copy Last Response", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = last.content
                        }

                        if viewModel.ttsService.isSpeaking {
                            Button("Stop Speaking", systemImage: "speaker.slash") {
                                viewModel.stopSpeaking()
                            }
                        } else {
                            Button("Read Aloud", systemImage: "speaker.wave.2") {
                                viewModel.speakLastResponse()
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $viewModel.showToolApproval) {
            ToolApprovalSheet(
                toolCall: viewModel.agent.pendingToolCall,
                localeManager: viewModel.localeManager,
                onApprove: { viewModel.approveToolCall() },
                onDeny: { viewModel.denyToolCall() }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.messages.count)
        .sensoryFeedback(.success, trigger: viewModel.showToolApproval)
        .onAppear {
            viewModel.setModelContext(modelContext)
            viewModel.loadOrCreateConversation(existing: existingConversation)
        }
        .animation(.default, value: viewModel.isGenerating)
    }

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.messages, id: \.id) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 12)

                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.count) { _, _ in
                withAnimation(.spring(duration: 0.3)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.streamingContent) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
