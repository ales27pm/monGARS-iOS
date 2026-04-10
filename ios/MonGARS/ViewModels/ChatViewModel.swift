import SwiftData
import SwiftUI

@Observable
@MainActor
final class ChatViewModel {
    let agent: AgentOrchestrator
    let localeManager: LocaleManager
    let speechRecognizer: SpeechRecognizer
    let ttsService: TextToSpeechService
    let runtimeCoordinator: ModelRuntimeCoordinator

    var inputText: String = ""
    var isGenerating: Bool = false
    var streamingContent: String = ""
    var showToolApproval: Bool = false
    var errorMessage: String?

    private var currentConversation: Conversation?
    private var modelContext: ModelContext?
    private var generationTask: Task<Void, Never>?

    init(
        agent: AgentOrchestrator,
        localeManager: LocaleManager,
        speechRecognizer: SpeechRecognizer,
        ttsService: TextToSpeechService,
        runtimeCoordinator: ModelRuntimeCoordinator
    ) {
        self.agent = agent
        self.localeManager = localeManager
        self.speechRecognizer = speechRecognizer
        self.ttsService = ttsService
        self.runtimeCoordinator = runtimeCoordinator
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    func loadOrCreateConversation(existing: Conversation?) {
        if let existing {
            currentConversation = existing
        } else {
            let conversation = Conversation(language: localeManager.currentLanguage)
            modelContext?.insert(conversation)
            currentConversation = conversation
        }
    }

    var conversation: Conversation? { currentConversation }

    var messages: [Message] {
        currentConversation?.sortedMessages ?? []
    }

    var isModelReady: Bool {
        runtimeCoordinator.llmReady
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        let userMessage = Message(
            content: text,
            role: .user,
            language: localeManager.currentLanguage
        )
        addMessage(userMessage)

        generateResponse()
    }

    func sendVoiceInput() {
        let text = speechRecognizer.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        speechRecognizer.transcribedText = ""

        let userMessage = Message(
            content: text,
            role: .user,
            language: localeManager.currentLanguage
        )
        addMessage(userMessage)

        generateResponse()
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false

        if !streamingContent.isEmpty {
            let assistantMessage = Message(
                content: streamingContent,
                role: .assistant,
                status: .complete,
                language: localeManager.currentLanguage
            )
            addMessage(assistantMessage)
            streamingContent = ""
        }
    }

    func speakLastResponse() {
        guard let lastAssistant = messages.last(where: { $0.isAssistant }) else { return }
        ttsService.speak(lastAssistant.content, language: localeManager.currentLanguage)
    }

    func stopSpeaking() {
        ttsService.stop()
    }

    func approveToolCall() {
        showToolApproval = false
        Task {
            let result = await agent.approveToolCall()
            switch result {
            case .success(let output):
                let toolMessage = Message(content: output, role: .tool, language: localeManager.currentLanguage)
                addMessage(toolMessage)
            case .failure(let error):
                errorMessage = error
            case .cancelled:
                break
            }
        }
    }

    func denyToolCall() {
        showToolApproval = false
        agent.denyToolCall()
    }

    private func generateResponse() {
        guard isModelReady else {
            let placeholder = Message(
                content: localeManager.localizedString(
                    "The AI model needs to be downloaded before I can respond. Please go to Settings to download the model.",
                    "Le mod\u{00E8}le IA doit \u{00EA}tre t\u{00E9}l\u{00E9}charg\u{00E9} avant que je puisse r\u{00E9}pondre. Veuillez aller dans les R\u{00E9}glages pour t\u{00E9}l\u{00E9}charger le mod\u{00E8}le."
                ),
                role: .assistant,
                language: localeManager.currentLanguage
            )
            addMessage(placeholder)
            return
        }

        isGenerating = true
        streamingContent = ""
        errorMessage = nil

        generationTask = Task {
            do {
                let stream = agent.generateResponse(
                    messages: messages,
                    language: localeManager.currentLanguage
                )

                for try await token in stream {
                    guard !Task.isCancelled else { break }
                    streamingContent += token
                }

                if !Task.isCancelled {
                    let assistantMessage = Message(
                        content: streamingContent,
                        role: .assistant,
                        language: localeManager.currentLanguage
                    )
                    addMessage(assistantMessage)

                    if agent.pendingToolCall != nil {
                        showToolApproval = true
                    }
                }
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    let errorMsg = Message(
                        content: localeManager.localizedString(
                            "I encountered an error generating a response. Please try again.",
                            "J'ai rencontr\u{00E9} une erreur en g\u{00E9}n\u{00E9}rant une r\u{00E9}ponse. Veuillez r\u{00E9}essayer."
                        ),
                        role: .assistant,
                        status: .error,
                        language: localeManager.currentLanguage
                    )
                    addMessage(errorMsg)
                }
            }

            streamingContent = ""
            isGenerating = false
            generationTask = nil
        }
    }

    private func addMessage(_ message: Message) {
        message.conversation = currentConversation
        currentConversation?.messages.append(message)
        currentConversation?.updatedAt = Date()
    }
}
