import Foundation
import SwiftData

nonisolated enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

nonisolated enum MessageStatus: String, Codable, Sendable {
    case sending
    case streaming
    case complete
    case error
}

@Model
class Message {
    var id: UUID
    var content: String
    var role: String
    var status: String
    var createdAt: Date
    var language: String?
    var toolCallName: String?
    var toolCallArgs: String?
    var conversation: Conversation?

    init(
        content: String,
        role: MessageRole,
        status: MessageStatus = .complete,
        language: AppLanguage? = nil,
        toolCallName: String? = nil,
        toolCallArgs: String? = nil
    ) {
        self.id = UUID()
        self.content = content
        self.role = role.rawValue
        self.status = status.rawValue
        self.createdAt = Date()
        self.language = language?.rawValue
        self.toolCallName = toolCallName
        self.toolCallArgs = toolCallArgs
    }

    var messageRole: MessageRole {
        MessageRole(rawValue: role) ?? .user
    }

    var messageStatus: MessageStatus {
        MessageStatus(rawValue: status) ?? .complete
    }

    var isUser: Bool { messageRole == .user }
    var isAssistant: Bool { messageRole == .assistant }
    var isStreaming: Bool { messageStatus == .streaming }
}
