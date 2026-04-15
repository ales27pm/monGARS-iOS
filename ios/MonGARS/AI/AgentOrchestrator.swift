import Foundation
import os

@Observable
@MainActor
final class AgentOrchestrator {
    private let logger = Logger(subsystem: "com.mongars.ai", category: "agent")
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
        case .llama3, .dolphin:
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

                    if let toolCall = try parseToolCall(from: fullResponse) {
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
                } catch let parseError as ToolCallParsingError {
                    logger.warning("Invalid tool-call output. \(parseError.logMessage, privacy: .public)")
                    continuation.finish(throwing: AgentError.toolCallValidationFailed(parseError.localizedDescription))
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
        case .llama3, .dolphin:
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

    private func parseToolCall(from response: String) throws -> ToolCallRequest? {
        guard let parsedCall = try ToolCallParser.parseToolCall(from: response, schemas: toolRegistry.registeredSchemas) else {
            return nil
        }

        let schemaRequiresApproval = toolRegistry.requiresApproval(toolName: parsedCall.toolName)
        let isNetwork = toolRegistry.isNetworkRequired(toolName: parsedCall.toolName)
        let forceApproval = isNetwork && networkPolicy.askBeforeNetworkUse
        let requiresApproval = schemaRequiresApproval || forceApproval

        return ToolCallRequest(toolName: parsedCall.toolName, arguments: parsedCall.arguments, requiresApproval: requiresApproval)
    }
}

nonisolated enum AgentError: Error, Sendable {
    case modelNotReady
    case toolExecutionFailed(String)
    case toolCallValidationFailed(String)
    case promptTooLong
}

extension AgentError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .modelNotReady:
            "Model is not ready."
        case .toolExecutionFailed(let message):
            message
        case .toolCallValidationFailed(let message):
            message
        case .promptTooLong:
            "Prompt exceeded model context limits."
        }
    }
}

nonisolated struct ParsedToolCall: Equatable, Sendable {
    let toolName: String
    let arguments: [String: String]
}

nonisolated enum ToolCallParsingError: Error, Sendable, Equatable {
    case unbalancedEnvelope
    case malformedJSON
    case missingToolName
    case unknownTool(String)
    case argumentsMustBeObject
    case missingRequiredArguments([String])
    case invalidArgumentType(argument: String, expected: ToolParameterType)
    case nonScalarUnknownArgument(String)

    nonisolated var logMessage: String {
        switch self {
        case .unbalancedEnvelope:
            "Tool-call tags are unbalanced."
        case .malformedJSON:
            "Tool-call payload is not valid JSON."
        case .missingToolName:
            "Tool-call payload is missing a valid tool name."
        case .unknownTool(let name):
            "Unknown tool '\(name)'."
        case .argumentsMustBeObject:
            "Tool-call arguments must be a JSON object."
        case .missingRequiredArguments(let names):
            "Missing required tool arguments: \(names.joined(separator: ", "))."
        case .invalidArgumentType(let argument, let expected):
            "Argument '\(argument)' does not match expected type '\(expected.rawValue)'."
        case .nonScalarUnknownArgument(let name):
            "Unknown argument '\(name)' must be a scalar value."
        }
    }
}

extension ToolCallParsingError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "Tool call validation failed: unknown tool '\(name)'."
        case .missingRequiredArguments(let names):
            "Tool call validation failed: missing required argument(s): \(names.joined(separator: ", "))."
        default:
            "Tool call validation failed: \(logMessage)"
        }
    }
}

nonisolated enum ToolJSONValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case object([String: ToolJSONValue])
    case array([ToolJSONValue])
    case null

    nonisolated var scalarString: String? {
        switch self {
        case .string(let value):
            value
        case .integer(let value):
            String(value)
        case .double(let value):
            String(value)
        case .boolean(let value):
            value ? "true" : "false"
        case .object, .array, .null:
            nil
        }
    }

    nonisolated var isNull: Bool {
        if case .null = self {
            true
        } else {
            false
        }
    }
}

nonisolated enum ToolCallParser {
    private static let toolCallOpenTag = "<tool_call>"
    private static let toolCallCloseTag = "</tool_call>"

    static func parseToolCall(from response: String, schemas: [ToolSchema]) throws -> ParsedToolCall? {
        guard let payload = try extractFinalToolCallPayload(from: response) else {
            return nil
        }

        guard let data = payload.data(using: .utf8) else {
            throw ToolCallParsingError.malformedJSON
        }

        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ToolCallParsingError.malformedJSON
        }

        guard let root = rootObject as? [String: Any] else {
            throw ToolCallParsingError.malformedJSON
        }

        guard let rawToolName = root["name"] as? String else {
            throw ToolCallParsingError.missingToolName
        }

        let toolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else {
            throw ToolCallParsingError.missingToolName
        }

        guard let schema = schemas.first(where: { $0.name == toolName }) else {
            throw ToolCallParsingError.unknownTool(toolName)
        }

        let rawArguments = try parseArguments(root["arguments"])
        let normalizedArguments = try normalizeArguments(rawArguments, schema: schema)

        return ParsedToolCall(toolName: toolName, arguments: normalizedArguments)
    }

    static func extractFinalToolCallPayload(from response: String) throws -> String? {
        var cursor = response.startIndex
        var openTagEnds: [String.Index] = []
        var sawAnyToolTag = false
        var finalPayloadRange: Range<String.Index>?

        while cursor < response.endIndex {
            let nextOpen = response.range(of: toolCallOpenTag, range: cursor..<response.endIndex)
            let nextClose = response.range(of: toolCallCloseTag, range: cursor..<response.endIndex)

            if let open = nextOpen, (nextClose == nil || open.lowerBound < nextClose!.lowerBound) {
                sawAnyToolTag = true
                openTagEnds.append(open.upperBound)
                cursor = open.upperBound
                continue
            }

            if let close = nextClose {
                sawAnyToolTag = true
                guard let payloadStart = openTagEnds.popLast() else {
                    throw ToolCallParsingError.unbalancedEnvelope
                }
                finalPayloadRange = payloadStart..<close.lowerBound
                cursor = close.upperBound
                continue
            }

            break
        }

        if !openTagEnds.isEmpty {
            throw ToolCallParsingError.unbalancedEnvelope
        }

        guard sawAnyToolTag else {
            return nil
        }

        guard let finalPayloadRange else {
            throw ToolCallParsingError.unbalancedEnvelope
        }

        return String(response[finalPayloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseArguments(_ rawArguments: Any?) throws -> [String: ToolJSONValue] {
        guard let rawArguments else {
            return [:]
        }

        if rawArguments is NSNull {
            return [:]
        }

        guard let argumentObject = rawArguments as? [String: Any] else {
            throw ToolCallParsingError.argumentsMustBeObject
        }

        var parsed: [String: ToolJSONValue] = [:]
        parsed.reserveCapacity(argumentObject.count)

        for (name, rawValue) in argumentObject {
            parsed[name] = try parseJSONValue(rawValue)
        }

        return parsed
    }

    private static func parseJSONValue(_ rawValue: Any) throws -> ToolJSONValue {
        if rawValue is NSNull {
            return .null
        }

        if let stringValue = rawValue as? String {
            return .string(stringValue)
        }

        if let numberValue = rawValue as? NSNumber {
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                return .boolean(numberValue.boolValue)
            }

            let asDouble = numberValue.doubleValue
            if asDouble.isFinite,
               asDouble.rounded(.towardZero) == asDouble,
               asDouble >= Double(Int.min),
               asDouble <= Double(Int.max) {
                return .integer(Int(asDouble))
            }
            return .double(asDouble)
        }

        if let objectValue = rawValue as? [String: Any] {
            var object: [String: ToolJSONValue] = [:]
            object.reserveCapacity(objectValue.count)
            for (key, value) in objectValue {
                object[key] = try parseJSONValue(value)
            }
            return .object(object)
        }

        if let arrayValue = rawValue as? [Any] {
            return .array(try arrayValue.map(parseJSONValue))
        }

        throw ToolCallParsingError.malformedJSON
    }

    private static func normalizeArguments(_ rawArguments: [String: ToolJSONValue], schema: ToolSchema) throws -> [String: String] {
        let parameterByName = Dictionary(uniqueKeysWithValues: schema.parameters.map { ($0.name, $0) })
        var normalizedArguments: [String: String] = [:]
        normalizedArguments.reserveCapacity(rawArguments.count)

        for (argumentName, rawValue) in rawArguments {
            if rawValue.isNull {
                continue
            }

            if let parameter = parameterByName[argumentName] {
                guard let coercedValue = coerceArgument(rawValue, parameterType: parameter.type) else {
                    throw ToolCallParsingError.invalidArgumentType(argument: argumentName, expected: parameter.type)
                }
                normalizedArguments[argumentName] = coercedValue
                continue
            }

            guard let scalarValue = rawValue.scalarString else {
                throw ToolCallParsingError.nonScalarUnknownArgument(argumentName)
            }
            normalizedArguments[argumentName] = scalarValue
        }

        let missingRequired = schema.parameters
            .filter(\.required)
            .map(\.name)
            .filter { name in
                guard let value = normalizedArguments[name] else { return true }
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted()

        if !missingRequired.isEmpty {
            throw ToolCallParsingError.missingRequiredArguments(missingRequired)
        }

        return normalizedArguments
    }

    private static func coerceArgument(_ value: ToolJSONValue, parameterType: ToolParameterType) -> String? {
        switch parameterType {
        case .string:
            return value.scalarString
        case .integer:
            switch value {
            case .integer(let intValue):
                return String(intValue)
            case .double(let doubleValue):
                guard doubleValue.isFinite,
                      doubleValue.rounded(.towardZero) == doubleValue,
                      doubleValue >= Double(Int.min),
                      doubleValue <= Double(Int.max) else {
                    return nil
                }
                return String(Int(doubleValue))
            case .string(let stringValue):
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let intValue = Int(trimmed) else { return nil }
                return String(intValue)
            default:
                return nil
            }
        case .boolean:
            switch value {
            case .boolean(let boolValue):
                return boolValue ? "true" : "false"
            case .integer(let intValue):
                if intValue == 0 { return "false" }
                if intValue == 1 { return "true" }
                return nil
            case .string(let stringValue):
                let lowered = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lowered == "true" || lowered == "1" || lowered == "yes" {
                    return "true"
                }
                if lowered == "false" || lowered == "0" || lowered == "no" {
                    return "false"
                }
                return nil
            default:
                return nil
            }
        case .date:
            guard case .string(let stringValue) = value else { return nil }
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
