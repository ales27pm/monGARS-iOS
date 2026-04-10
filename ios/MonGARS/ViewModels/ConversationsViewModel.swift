import SwiftData
import SwiftUI

@Observable
@MainActor
final class ConversationsViewModel {
    let localeManager: LocaleManager
    var searchText: String = ""

    init(localeManager: LocaleManager) {
        self.localeManager = localeManager
    }

    func filteredConversations(_ conversations: [Conversation]) -> [Conversation] {
        guard !searchText.isEmpty else {
            return conversations.sorted { $0.updatedAt > $1.updatedAt }
        }
        return conversations
            .filter { conv in
                conv.displayTitle.localizedStandardContains(searchText) ||
                conv.messages.contains { $0.content.localizedStandardContains(searchText) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func deleteConversation(_ conversation: Conversation, context: ModelContext) {
        context.delete(conversation)
    }
}
