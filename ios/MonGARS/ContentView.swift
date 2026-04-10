import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(LocaleManager.self) private var localeManager
    @Environment(ModelDownloadManager.self) private var modelDownloadManager
    @Environment(PermissionsManager.self) private var permissionsManager
    @Environment(ToolRegistry.self) private var toolRegistry

    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding = false
    @State private var selectedTab: AppTab = .conversations
    @State private var selectedConversation: Conversation?
    @State private var showNewChat = false
    @State private var runtimeCoordinator: ModelRuntimeCoordinator?

    var body: some View {
        if !hasCompletedOnboarding {
            onboardingFlow
        } else {
            mainApp
                .task {
                    if runtimeCoordinator == nil {
                        let coordinator = ModelRuntimeCoordinator(modelDownloadManager: modelDownloadManager)
                        runtimeCoordinator = coordinator
                        await coordinator.loadAllAvailable()
                    }
                }
        }
    }

    private var onboardingFlow: some View {
        OnboardingView(
            viewModel: OnboardingViewModel(
                modelDownloadManager: modelDownloadManager,
                localeManager: localeManager
            )
        )
    }

    private var mainApp: some View {
        TabView(selection: $selectedTab) {
            Tab(localeManager.localizedString("Conversations", "Conversations"), systemImage: "bubble.left.and.bubble.right", value: .conversations) {
                NavigationStack {
                    ConversationsListView(
                        viewModel: ConversationsViewModel(localeManager: localeManager),
                        onSelectConversation: { conversation in
                            selectedConversation = conversation
                            showNewChat = true
                        }
                    )
                    .navigationTitle("monGARS")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                selectedConversation = nil
                                showNewChat = true
                            } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .accessibilityLabel(localeManager.localizedString("New Conversation", "Nouvelle conversation"))
                        }
                    }
                    .navigationDestination(isPresented: $showNewChat) {
                        chatDestination
                    }
                }
            }

            Tab(localeManager.localizedString("Settings", "R\u{00E9}glages"), systemImage: "gear", value: .settings) {
                NavigationStack {
                    SettingsView(
                        viewModel: SettingsViewModel(
                            localeManager: localeManager,
                            modelDownloadManager: modelDownloadManager,
                            permissionsManager: permissionsManager
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var chatDestination: some View {
        if let coordinator = runtimeCoordinator {
            let agent = AgentOrchestrator(
                llmEngine: coordinator.llmEngine,
                toolRegistry: toolRegistry,
                localeManager: localeManager
            )

            ChatView(
                viewModel: ChatViewModel(
                    agent: agent,
                    localeManager: localeManager,
                    speechRecognizer: SpeechRecognizer(),
                    ttsService: TextToSpeechService(),
                    runtimeCoordinator: coordinator
                ),
                existingConversation: selectedConversation
            )
        } else {
            ProgressView()
        }
    }
}

enum AppTab: Hashable {
    case conversations
    case settings
}
