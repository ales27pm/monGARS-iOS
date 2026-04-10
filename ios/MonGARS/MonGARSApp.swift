import SwiftData
import SwiftUI

@main
struct MonGARSApp: App {
    @State private var localeManager = LocaleManager()
    @State private var modelDownloadManager = ModelDownloadManager()
    @State private var permissionsManager = PermissionsManager()
    @State private var toolRegistry = ToolRegistry()
    @State private var llmEngine = LLMEngine()
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var ttsService = TextToSpeechService()

    private var agent: AgentOrchestrator {
        AgentOrchestrator(
            llmEngine: llmEngine,
            toolRegistry: toolRegistry,
            localeManager: localeManager
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(localeManager)
                .environment(modelDownloadManager)
                .environment(permissionsManager)
                .environment(toolRegistry)
        }
        .modelContainer(for: [Conversation.self, Message.self])
    }
}
