import Foundation

@Observable
@MainActor
final class AgentOrchestrator {
    let llmEngine: LLMEngine
    let toolRegistry: ToolRegistry
    let localeManager: LocaleManager
    let memoryService: SemanticMemoryService?

    var pendingToolCall: ToolCallRequest?
    var isProcessing: Bool = false

    init(llmEngine: LLMEngine, toolRegistry: ToolRegistry, localeManager: LocaleManager, memoryService: SemanticMemoryService? = nil) {
        self.llmEngine = llmEngine
        self.toolRegistry = toolRegistry
        self.localeManager = localeManager
        self.memoryService = memoryService
    }

    func compilePrompt(messages: [Message], language: AppLanguage, retrievedContext: String? = nil) -> String {
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

                do {
                    for try await token in stream {
                        if token.contains("<|eot_id|>") || token.contains("<|end_of_text|>") {
                            break
                        }
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
        let result = await toolRegistry.execute(toolName: call.toolName, arguments: call.arguments)
        pendingToolCall = nil
        return result
    }

    func denyToolCall() {
        pendingToolCall = nil
    }

    private func systemPrompt(for language: AppLanguage) -> String {
        let toolDescriptions = toolRegistry.availableToolDescriptions(offlineOnly: false)

        let base: String
        switch language {
        case .englishCA:
            base = """
            You are monGARS, a helpful bilingual assistant running entirely on this device. \
            You respect user privacy and operate locally. \
            You speak English (Canadian) and French (Canadian). \
            \(language.systemPromptLanguageInstruction)
            """
        case .frenchCA:
            base = """
            Tu es monGARS, un assistant bilingue qui fonctionne enti\u{00E8}rement sur cet appareil. \
            Tu respectes la vie priv\u{00E9}e de l'utilisateur et tu op\u{00E8}res localement. \
            Tu parles anglais (canadien) et fran\u{00E7}ais (canadien). \
            \(language.systemPromptLanguageInstruction)
            """
        }

        if toolDescriptions.isEmpty {
            return base
        }

        return base + "\n\nAvailable tools:\n" + toolDescriptions
    }

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
        let requiresApproval = toolRegistry.requiresApproval(toolName: name)

        return ToolCallRequest(toolName: name, arguments: args, requiresApproval: requiresApproval)
    }
}

nonisolated enum AgentError: Error, Sendable {
    case modelNotReady
    case toolExecutionFailed(String)
    case promptTooLong
}
