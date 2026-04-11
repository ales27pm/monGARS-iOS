import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(LocaleManager.self) private var localeManager
    @Environment(ModelDownloadManager.self) private var modelDownloadManager
    @Environment(PermissionsManager.self) private var permissionsManager
    @Environment(ToolRegistry.self) private var toolRegistry
    @Environment(NetworkPolicyService.self) private var networkPolicy

    @State private var selectedTab: AppTab = .conversations
    @State private var selectedConversation: Conversation?
    @State private var showNewChat = false
    @State private var runtimeCoordinator: ModelRuntimeCoordinator?
    @State private var memoryService: SemanticMemoryService?
    @State private var embeddingStore = EmbeddingStore()

    private var hasCompletedOnboarding: Bool {
        SecureStoreService.syncExists(key: .onboardingCompleted)
    }

    private var isChatReady: Bool {
        modelDownloadManager.isChatReady
    }

    private var isSemanticMemoryReady: Bool {
        modelDownloadManager.isSemanticMemoryReady
    }

    var body: some View {
        if !hasCompletedOnboarding {
            onboardingFlow
        } else {
            mainApp
                .task {
                    if runtimeCoordinator == nil {
                        let coordinator = ModelRuntimeCoordinator(modelDownloadManager: modelDownloadManager)
                        runtimeCoordinator = coordinator

                        do {
                            try await embeddingStore.open()
                        } catch {
                            print("EmbeddingStore open failed: \(error)")
                        }

                        let memory = SemanticMemoryService(
                            embeddingStore: embeddingStore,
                            embeddingEngine: coordinator.embeddingEngine
                        )
                        memoryService = memory

                        await coordinator.loadAllAvailable()
                    }
                }
                .onChange(of: modelDownloadManager.llmState) { _, newState in
                    if newState.isInstalled || newState.isInstalledPartially {
                        if let coordinator = runtimeCoordinator, !coordinator.llmReady {
                            Task {
                                await coordinator.loadLLMIfAvailable()
                            }
                        }
                    }
                }
                .onChange(of: modelDownloadManager.embeddingState) { _, newState in
                    if newState.isInstalled {
                        if let coordinator = runtimeCoordinator, !coordinator.embeddingReady {
                            Task {
                                await coordinator.loadEmbeddingIfAvailable()
                            }
                        }
                    }
                }
                .onChange(of: modelDownloadManager.selectedChatSourceID) { _, _ in
                    guard let coordinator = runtimeCoordinator else { return }
                    coordinator.requestChatReloadForSelectionChange()
                }
                .onChange(of: modelDownloadManager.selectedEmbeddingSourceID) { _, _ in
                    guard let coordinator = runtimeCoordinator else { return }
                    coordinator.requestEmbeddingReloadForSelectionChange()
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
                            permissionsManager: permissionsManager,
                            networkPolicy: networkPolicy
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var chatDestination: some View {
        if let coordinator = runtimeCoordinator {
            let selectedChatSourceID = modelDownloadManager.selectedChatSourceID
            let agent = AgentOrchestrator(
                llmEngine: coordinator.llmEngine,
                toolRegistry: toolRegistry,
                localeManager: localeManager,
                networkPolicy: networkPolicy,
                promptFormat: coordinator.activePromptFormat,
                memoryService: memoryService
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
            .id(selectedChatSourceID)
        } else {
            ProgressView()
        }
    }
}

enum AppTab: Hashable {
    case conversations
    case settings
}
