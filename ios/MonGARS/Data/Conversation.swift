import Foundation
import SwiftData

@Model
class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var language: String
    @Relationship(deleteRule: .cascade) var messages: [Message] = []

    init(title: String = "", language: AppLanguage = .englishCA) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.language = language.rawValue
    }

    var appLanguage: AppLanguage {
        AppLanguage(rawValue: language) ?? .englishCA
    }

    var sortedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    var lastMessagePreview: String {
        guard let last = sortedMessages.last else { return "" }
        let preview = last.content.prefix(80)
        return preview.count < last.content.count ? "\(preview)..." : String(preview)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let first = sortedMessages.first(where: { $0.role == MessageRole.user.rawValue }) {
            let t = first.content.prefix(40)
            return t.count < first.content.count ? "\(t)..." : String(t)
        }
        return appLanguage == .frenchCA ? "Nouvelle conversation" : "New Conversation"
    }
}
