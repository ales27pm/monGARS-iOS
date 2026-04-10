import SwiftData
import SwiftUI

@main
struct MonGARSApp: App {
    @State private var localeManager = LocaleManager()
    @State private var modelDownloadManager = ModelDownloadManager()
    @State private var permissionsManager = PermissionsManager()
    @State private var toolRegistry = ToolRegistry()
    @State private var locationService = LocationService()
    @State private var runtimeCoordinator: ModelRuntimeCoordinator?
    @State private var embeddingStore = EmbeddingStore()
    @State private var toolsRegistered = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(localeManager)
                .environment(modelDownloadManager)
                .environment(permissionsManager)
                .environment(toolRegistry)
                .environment(locationService)
                .task {
                    if !toolsRegistered {
                        registerTools()
                        toolsRegistered = true
                    }
                    do {
                        try await embeddingStore.open()
                    } catch {
                        print("EmbeddingStore open failed: \(error)")
                    }
                    if runtimeCoordinator == nil {
                        let coordinator = ModelRuntimeCoordinator(modelDownloadManager: modelDownloadManager)
                        runtimeCoordinator = coordinator
                        await coordinator.loadAllAvailable()
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
    }
}
