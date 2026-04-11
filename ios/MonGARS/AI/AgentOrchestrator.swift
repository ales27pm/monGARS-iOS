import Foundation

@Observable
@MainActor
final class AgentOrchestrator {
    let llmEngine: LLMEngine
    let toolRegistry: ToolRegistry
    let localeManager: LocaleManager
    let memoryService: SemanticMemoryService?
    let networkPolicy: NetworkPolicyService
    let promptFormat: PromptFormat

    var pendingToolCall: ToolCallRequest?
    var isProcessing: Bool = false

    init(llmEngine: LLMEngine, toolRegistry: ToolRegistry, localeManager: LocaleManager, networkPolicy: NetworkPolicyService, promptFormat: PromptFormat = .llama3, memoryService: SemanticMemoryService? = nil) {
        self.llmEngine = llmEngine
        self.toolRegistry = toolRegistry
        self.localeManager = localeManager
        self.networkPolicy = networkPolicy
        self.promptFormat = promptFormat
        self.memoryService = memoryService
    }

    func compilePrompt(messages: [Message], language: AppLanguage, retrievedContext: String? = nil) -> String {
        switch promptFormat {
        case .llama3:
            return compileLlama3Prompt(messages: messages, language: language, retrievedContext: retrievedContext)
        case .qwen:
            return compileQwenPrompt(messages: messages, language: language, retrievedContext: retrievedContext)
        }
    }

    func generateResponse(messages: [Message], language: AppLanguage, conversationId: String? = nil, config: GenerationConfig = .default) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                isProcessing = true
                defer { isProcessing = false }

                let engineReady = await llmEngine.isReady
                guard engineReady else {
                    continuation.finish(throwing: AgentError.modelNotReady)
                    return
                }

                var retrievedContext: String?
                if let memoryService, let lastUserMsg = messages.last(where: { $0.messageRole == .user }) {
                    retrievedContext = await memoryService.buildContextBlock(
                        for: lastUserMsg.content,
                        language: language.rawValue
                    )
                }

                let prompt = compilePrompt(messages: messages, language: language, retrievedContext: retrievedContext)

                let stream = await llmEngine.generate(
                    prompt: prompt,
                    config: config
                )

                var fullResponse = ""
                let stopSequences = stopTokenSequences

                do {
                    for try await token in stream {
                        var shouldStop = false
                        for seq in stopSequences {
                            if token.contains(seq) {
                                shouldStop = true
                                break
                            }
                        }
                        if shouldStop { break }

                        fullResponse += token
                        continuation.yield(token)
                    }

                    if let toolCall = parseToolCall(from: fullResponse) {
                        pendingToolCall = toolCall
                    }

                    if let memoryService,
                       let lastUserMsg = messages.last(where: { $0.messageRole == .user }),
                       !fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let convId = conversationId ?? "unknown"
                        await memoryService.ingestConversationTurn(
                            userMessage: lastUserMsg.content,
                            assistantResponse: fullResponse,
                            conversationId: convId,
                            language: language.rawValue
                        )
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func approveToolCall() async -> ToolCallResult {
        guard let call = pendingToolCall else { return .cancelled }

        if toolRegistry.isNetworkRequired(toolName: call.toolName) {
            guard networkPolicy.isToolAllowed(call.toolName) else {
                pendingToolCall = nil
                return .failure("Network tool '\(call.toolName)' is disabled. Enable it in Settings > Network Tools.")
            }
        }

        let result = await toolRegistry.execute(toolName: call.toolName, arguments: call.arguments)
        pendingToolCall = nil
        return result
    }

    func denyToolCall() {
        pendingToolCall = nil
    }

    // MARK: - Stop Sequences

    private var stopTokenSequences: [String] {
        switch promptFormat {
        case .llama3:
            ["<|eot_id|>", "<|end_of_text|>"]
        case .qwen:
            ["<|im_end|>", "<|endoftext|>"]
        }
    }

    // MARK: - Llama 3 Prompt Format

    private func compileLlama3Prompt(messages: [Message], language: AppLanguage, retrievedContext: String?) -> String {
        var prompt = "<|begin_of_text|>"

        prompt += "<|start_header_id|>system<|end_header_id|>\n\n"
        prompt += systemPrompt(for: language)

        if let context = retrievedContext {
            prompt += "\n\n" + context
        }

        prompt += "<|eot_id|>"

        let recentMessages = Array(messages.suffix(20))

        for message in recentMessages {
            let role = message.messageRole
            guard role == .user || role == .assistant else { continue }

            prompt += "<|start_header_id|>\(role.rawValue)<|end_header_id|>\n\n"
            prompt += message.content
            prompt += "<|eot_id|>"
        }

        prompt += "<|start_header_id|>assistant<|end_header_id|>\n\n"

        return prompt
    }

    // MARK: - Qwen Prompt Format

    private func compileQwenPrompt(messages: [Message], language: AppLanguage, retrievedContext: String?) -> String {
        var prompt = "<|im_start|>system\n"
        prompt += systemPrompt(for: language)

        if let context = retrievedContext {
            prompt += "\n\n" + context
        }

        prompt += "<|im_end|>\n"

        let recentMessages = Array(messages.suffix(20))

        for message in recentMessages {
            let role = message.messageRole
            guard role == .user || role == .assistant else { continue }

            prompt += "<|im_start|>\(role.rawValue)\n"
            prompt += message.content
            prompt += "<|im_end|>\n"
        }

        prompt += "<|im_start|>assistant\n"

        return prompt
    }

    // MARK: - System Prompt

    private func systemPrompt(for language: AppLanguage) -> String {
        let toolDescriptions = toolRegistry.availableToolDescriptions(policy: networkPolicy)

        let networkClause: String
        if networkPolicy.isNetworkAllowed {
            switch language {
            case .englishCA:
                networkClause = "Some tools may access the internet when enabled by the user."
            case .frenchCA:
                networkClause = "Certains outils peuvent acc\u{00E9}der \u{00E0} Internet lorsqu'ils sont activ\u{00E9}s par l'utilisateur."
            }
        } else {
            switch language {
            case .englishCA:
                networkClause = "You are currently in offline mode. Only local tools are available."
            case .frenchCA:
                networkClause = "Tu es pr\u{00E9}sentement en mode hors ligne. Seuls les outils locaux sont disponibles."
            }
        }

        let base: String
        switch language {
        case .englishCA:
            base = """
            You are monGARS, a helpful bilingual assistant. \
            Your core reasoning, memory, and voice capabilities run entirely on this device. \
            You respect user privacy. \
            You speak English (Canadian) and French (Canadian). \
            \(networkClause) \
            \(language.systemPromptLanguageInstruction)
            """
        case .frenchCA:
            base = """
            Tu es monGARS, un assistant bilingue. \
            Ton raisonnement, ta m\u{00E9}moire et tes capacit\u{00E9}s vocales fonctionnent enti\u{00E8}rement sur cet appareil. \
            Tu respectes la vie priv\u{00E9}e de l'utilisateur. \
            Tu parles anglais (canadien) et fran\u{00E7}ais (canadien). \
            \(networkClause) \
            \(language.systemPromptLanguageInstruction)
            """
        }

        if toolDescriptions.isEmpty {
            return base
        }

        return base + "\n\nAvailable tools:\n" + toolDescriptions
    }

    // MARK: - Tool Parsing

    private func parseToolCall(from response: String) -> ToolCallRequest? {
        guard response.contains("<tool_call>") else { return nil }

        guard let startRange = response.range(of: "<tool_call>"),
              let endRange = response.range(of: "</tool_call>") else {
            return nil
        }

        let jsonString = String(response[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = parsed["name"] as? String else {
            return nil
        }

        let args = (parsed["arguments"] as? [String: String]) ?? [:]
        let schemaRequiresApproval = toolRegistry.requiresApproval(toolName: name)
        let isNetwork = toolRegistry.isNetworkRequired(toolName: name)
        let forceApproval = isNetwork && networkPolicy.askBeforeNetworkUse
        let requiresApproval = schemaRequiresApproval || forceApproval

        return ToolCallRequest(toolName: name, arguments: args, requiresApproval: requiresApproval)
    }
}

nonisolated enum AgentError: Error, Sendable {
    case modelNotReady
    case toolExecutionFailed(String)
    case promptTooLong
}
