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
        var manager = ModelDownloadManager()
        if let storedVariant = SecureStoreService.syncLoad(key: .selectedModelVariant),
           let variant = ModelVariant(rawValue: storedVariant) {
            manager.selectedLLMVariant = variant
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
