import SwiftData
import SwiftUI

@main
struct MonGARSApp: App {
    @State private var localeManager = LocaleManager()
    @State private var modelDownloadManager = ModelDownloadManager()
    @State private var permissionsManager = PermissionsManager()
    @State private var toolRegistry = ToolRegistry()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var ttsService = TextToSpeechService()
    @State private var runtimeCoordinator: ModelRuntimeCoordinator?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(localeManager)
                .environment(modelDownloadManager)
                .environment(permissionsManager)
                .environment(toolRegistry)
                .task {
                    if runtimeCoordinator == nil {
                        let coordinator = ModelRuntimeCoordinator(modelDownloadManager: modelDownloadManager)
                        runtimeCoordinator = coordinator
                        await coordinator.loadAllAvailable()
                    }
                }
        }
        .modelContainer(for: [Conversation.self, Message.self])
    }
}
