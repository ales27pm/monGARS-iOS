import SwiftData
import SwiftUI

@main
struct MonGARSApp: App {
    @State private var localeManager = LocaleManager()
    @State private var modelDownloadManager: ModelDownloadManager
    @State private var permissionsManager = PermissionsManager()
    @State private var toolRegistry = ToolRegistry()
    @State private var locationService = LocationService()
    @State private var networkPolicy = NetworkPolicyService()
    @State private var toolsRegistered = false

    init() {
        AppStoragePaths.preparePersistentDirectories()
        var manager = ModelDownloadManager()
        if let storedID = SecureStoreService.syncLoad(key: .selectedModelVariant) {
            if ModelSourceCatalog.chatSource(for: storedID) != nil {
                manager.selectedChatSourceID = storedID
            } else if let migrated = ModelSourceCatalog.migrateOldVariant(storedID),
                      ModelSourceCatalog.chatSource(for: migrated) != nil {
                manager.selectedChatSourceID = migrated
            }
        }
        if let storedEmbedID = SecureStoreService.syncLoad(key: .selectedEmbeddingSource) {
            if ModelSourceCatalog.embeddingSource(for: storedEmbedID) != nil {
                manager.selectedEmbeddingSourceID = storedEmbedID
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
