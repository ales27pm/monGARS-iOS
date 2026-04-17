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
            let unavailableMessage: String
            if let guidance = ModelRuntimeCoordinator.guidance(for: runtimeCoordinator.llmAvailabilityIssue) {
                unavailableMessage = localizedRuntimeGuidanceMessage(guidance)
            } else {
                unavailableMessage = localeManager.localizedString(
                    "The AI model is currently unavailable. Verify model settings and retry.",
                    "Le modèle IA est actuellement indisponible. Vérifiez les réglages du modèle et réessayez."
                )
            }

            let placeholder = Message(
                content: unavailableMessage,
                role: .assistant,
                language: localeManager.currentLanguage
            )
            addMessage(placeholder)
            return
        }

        isGenerating = true
        streamingContent = ""
        errorMessage = nil

        let conversationId = currentConversation?.id.uuidString

        generationTask = Task {
            do {
                let stream = agent.generateResponse(
                    messages: messages,
                    language: localeManager.currentLanguage,
                    conversationId: conversationId
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
                        content: userFacingGenerationErrorMessage(for: error),
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

    private func localizedRuntimeGuidanceMessage(_ guidance: ModelRuntimeCoordinator.LLMAvailabilityGuidance) -> String {
        switch localeManager.currentLanguage {
        case .englishCA:
            guidance.englishMessage
        case .frenchCA:
            guidance.frenchMessage
        }
    }

    private func userFacingGenerationErrorMessage(for error: Error) -> String {
        if let runtimeGuidance = ModelRuntimeCoordinator.guidance(for: runtimeCoordinator.llmAvailabilityIssue) {
            return localizedRuntimeGuidanceMessage(runtimeGuidance)
        }

        if let llmError = error as? LLMError {
            switch llmError {
            case .contextOverflow:
                return localeManager.localizedString(
                    "The prompt exceeded the model context window. Start a new chat or send a shorter message.",
                    "Le prompt a dépassé la fenêtre de contexte du modèle. Démarrez une nouvelle conversation ou envoyez un message plus court."
                )
            case .invalidModelOutput:
                return localeManager.localizedString(
                    "The model returned invalid output. Reinstall the selected model from Settings and try again.",
                    "Le modèle a renvoyé une sortie invalide. Réinstallez le modèle sélectionné depuis les Réglages et réessayez."
                )
            default:
                break
            }
        }

        if let agentError = error as? AgentError {
            if case .modelNotReady = agentError {
                return localeManager.localizedString(
                    "The model is not ready yet. Open Settings > Chat Model to install or reload a model.",
                    "Le modèle n'est pas encore prêt. Ouvrez Réglages > Modèle de conversation pour installer ou recharger un modèle."
                )
            }
        }

        return localeManager.localizedString(
            "I couldn't generate a response. Please try again. If this continues, reload or reinstall the selected model in Settings.",
            "Je n'ai pas pu générer de réponse. Veuillez réessayer. Si cela continue, rechargez ou réinstallez le modèle sélectionné dans les Réglages."
        )
    }
}
