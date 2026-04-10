import SwiftData
import SwiftUI

struct ConversationsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    let viewModel: ConversationsViewModel
    let onSelectConversation: (Conversation?) -> Void

    var body: some View {
        Group {
            if conversations.isEmpty {
                ContentUnavailableView(
                    viewModel.localeManager.localizedString("No Conversations", "Aucune conversation"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(viewModel.localeManager.localizedString(
                        "Start a new conversation to begin.",
                        "Commencez une nouvelle conversation."
                    ))
                )
            } else {
                List {
                    ForEach(viewModel.filteredConversations(conversations), id: \.id) { conversation in
                        Button {
                            onSelectConversation(conversation)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.deleteConversation(conversation, context: modelContext)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(
            text: Bindable(viewModel).searchText,
            prompt: viewModel.localeManager.localizedString("Search conversations", "Rechercher des conversations")
        )
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(conversation.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(conversation.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !conversation.lastMessagePreview.isEmpty {
                Text(conversation.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                Image(systemName: conversation.appLanguage == .frenchCA ? "globe.americas" : "globe.americas.fill")
                    .font(.caption2)
                Text(conversation.appLanguage.shortName)
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
