import Foundation

nonisolated enum ToolParameterType: String, Codable, Sendable {
    case string
    case integer
    case boolean
    case date
}

nonisolated struct ToolParameter: Codable, Sendable, Identifiable {
    let name: String
    let description: String
    let type: ToolParameterType
    let required: Bool

    nonisolated var id: String { name }
}

nonisolated struct ToolSchema: Codable, Sendable, Identifiable {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    let requiresApproval: Bool

    nonisolated var id: String { name }
}

nonisolated struct ToolCallRequest: Sendable, Identifiable {
    let id: UUID
    let toolName: String
    let arguments: [String: String]
    let requiresApproval: Bool

    init(toolName: String, arguments: [String: String], requiresApproval: Bool) {
        self.id = UUID()
        self.toolName = toolName
        self.arguments = arguments
        self.requiresApproval = requiresApproval
    }
}

nonisolated enum ToolCallResult: Sendable {
    case success(String)
    case failure(String)
    case cancelled
}

nonisolated enum ToolApprovalStatus: Sendable {
    case pending
    case approved
    case denied
}
