import SwiftData
import SwiftUI
import os

@main
struct MonGARSApp: App {
    private let logger = Logger(subsystem: "com.mongars.app", category: "startup")
    @State private var localeManager = LocaleManager()
    @State private var modelDownloadManager: ModelDownloadManager
    @State private var permissionsManager = PermissionsManager()
    @State private var toolRegistry = ToolRegistry()
    @State private var locationService = LocationService()
    @State private var networkPolicy = NetworkPolicyService()
    @State private var toolsRegistered = false

    init() {
        do {
            try AppStoragePaths.preparePersistentDirectories()
        } catch {
            logger.error("Failed to prepare app storage folders: \(error.localizedDescription, privacy: .public)")
        }
        let manager = ModelDownloadManager()
        let persistedChatSourceID = SecureStoreService.syncLoad(key: .selectedModelVariant)
        let persistedEmbeddingSourceID = SecureStoreService.syncLoad(key: .selectedEmbeddingSource)
        let selectionValidation = manager.validateSelectionOnLaunch(
            persistedChatSourceID: persistedChatSourceID,
            persistedEmbeddingSourceID: persistedEmbeddingSourceID
        )

        manager.selectedChatSourceID = selectionValidation.chatSourceID
        manager.selectedEmbeddingSourceID = selectionValidation.embeddingSourceID
        manager.refreshSelectedStates()

        if selectionValidation.chatNeedsPersistenceUpdate || selectionValidation.embeddingNeedsPersistenceUpdate {
            logger.info("Corrected persisted model selection. chat=\(selectionValidation.chatSourceID, privacy: .public), embedding=\(selectionValidation.embeddingSourceID, privacy: .public)")
            Task {
                if selectionValidation.chatNeedsPersistenceUpdate {
                    try? await SecureStoreService.shared.save(
                        key: .selectedModelVariant,
                        value: selectionValidation.chatSourceID
                    )
                }
                if selectionValidation.embeddingNeedsPersistenceUpdate {
                    try? await SecureStoreService.shared.save(
                        key: .selectedEmbeddingSource,
                        value: selectionValidation.embeddingSourceID
                    )
                }
            }
        }
        _modelDownloadManager = State(initialValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(localeManager)
                .environment(modelDownloadManager)
                .environment(permissionsManager)
                .environment(toolRegistry)
                .environment(locationService)
                .environment(networkPolicy)
                .task {
                    if !toolsRegistered {
                        registerTools()
                        toolsRegistered = true
                    }
                }
        }
        .modelContainer(for: [Conversation.self, Message.self])
    }

    private func registerTools() {
        toolRegistry.register(CreateReminderTool())
        toolRegistry.register(CreateCalendarEventTool())
        toolRegistry.register(SearchContactsTool())
        toolRegistry.register(GetLocationTool(locationService: locationService))
        toolRegistry.register(OpenMapsTool())
        toolRegistry.register(SendNotificationTool())
        toolRegistry.register(GetWeatherTool(locationService: locationService))
        toolRegistry.register(WebSearchTool())
    }
}
