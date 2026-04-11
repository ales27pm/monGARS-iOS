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
            switch runtimeCoordinator.llmAvailabilityIssue {
            case .notInstalled:
                unavailableMessage = localeManager.localizedString(
                    "The AI model is not installed yet. Please go to Settings to download it.",
                    "Le modèle IA n'est pas encore installé. Veuillez aller dans les Réglages pour le télécharger."
                )
            case .tokenizerMissing:
                unavailableMessage = localeManager.localizedString(
                    "The selected AI model is installed, but tokenizer files are missing. Reinstall the model from Settings.",
                    "Le modèle IA sélectionné est installé, mais les fichiers tokenizer sont manquants. Réinstallez le modèle depuis les Réglages."
                )
            case .runtimeLoadFailed(let category):
                switch category {
                case .modelFilesMissing:
                    unavailableMessage = localeManager.localizedString(
                        "The selected AI model is installed, but required model files are missing or invalid. Reinstall it from Settings.",
                        "Le modèle IA sélectionné est installé, mais des fichiers requis sont manquants ou invalides. Réinstallez-le depuis les Réglages."
                    )
                case .tokenizerInvalid:
                    unavailableMessage = localeManager.localizedString(
                        "The selected AI model is installed, but tokenizer data is invalid. Reinstall the model from Settings.",
                        "Le modèle IA sélectionné est installé, mais les données du tokenizer sont invalides. Réinstallez le modèle depuis les Réglages."
                    )
                case .outOfMemory:
                    unavailableMessage = localeManager.localizedString(
                        "The selected AI model could not be loaded due to memory pressure. Close other apps and try again.",
                        "Le modèle IA sélectionné n'a pas pu être chargé à cause d'une pression mémoire. Fermez d'autres apps et réessayez."
                    )
                case .initializationFailed:
                    unavailableMessage = localeManager.localizedString(
                        "The selected AI model is installed, but runtime initialization failed. Please retry from Settings.",
                        "Le modèle IA sélectionné est installé, mais l'initialisation du runtime a échoué. Veuillez réessayer depuis les Réglages."
                    )
                }
            case .none:
                unavailableMessage = localeManager.localizedString(
                    "The AI model is currently unavailable. Please verify model settings.",
                    "Le modèle IA est actuellement indisponible. Veuillez vérifier les réglages du modèle."
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
