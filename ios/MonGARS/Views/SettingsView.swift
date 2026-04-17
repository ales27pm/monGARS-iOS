import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            languageSection
            chatModelSection
            embeddingSection
            diagnosticsSection
            networkSection
            nativePermissionsSection
            voiceSection
            privacySection
            aboutSection
        }
        .navigationTitle(viewModel.localeManager.localizedString("Settings", "R\u{00E9}glages"))
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    viewModel.selectedLanguage = language
                } label: {
                    HStack {
                        Text(language.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        if viewModel.selectedLanguage == language {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Language", "Langue"))
        }
    }

    // MARK: - Chat Model Picker

    private var chatModelSection: some View {
        Section {
            ForEach(ModelSourceCatalog.chatSources) { source in
                Button {
                    viewModel.selectedChatSourceID = source.id
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.displayName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if let badge = source.badgeLabel {
                                    Text(badge)
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(source.isExperimental ? Color.orange : Color.blue, in: Capsule())
                                }
                            }
                            HStack(spacing: 8) {
                                Text(source.estimatedSizeDescription)
                                Text("•")
                                Text(source.formatLabel)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if viewModel.selectedChatSourceID == source.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                            chatModelStatus(for: source)
                        }
                    }
                }
            }

            if viewModel.modelDownloadManager.isLLMReady {
                HStack {
                    Text(viewModel.localeManager.localizedString("Storage Used", "Espace utilis\u{00E9}"))
                    Spacer()
                    Text(viewModel.modelDownloadManager.llmStorageUsed)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.modelDownloadManager.isLLMReady {
                Button(role: .destructive) {
                    viewModel.showDeleteConfirmation = true
                    viewModel.deleteTargetSourceID = viewModel.selectedChatSourceID
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Delete Model", "Supprimer le mod\u{00E8}le"),
                        systemImage: "trash"
                    )
                }
            } else if !viewModel.modelDownloadManager.llmState.isDownloading && !viewModel.modelDownloadManager.llmState.isInstalling {
                let source = viewModel.modelDownloadManager.selectedChatSource
                if source?.isAvailableForDownload == true {
                    Button {
                        viewModel.downloadModel(viewModel.selectedChatSourceID)
                    } label: {
                        Label(
                            viewModel.localeManager.localizedString("Download Model", "T\u{00E9}l\u{00E9}charger le mod\u{00E8}le"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                }
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Chat Model", "Mod\u{00E8}le de conversation"))
        } footer: {
            Text(viewModel.localeManager.localizedString(
                "Select the model used for conversation. Larger models are slower but more capable.",
                "S\u{00E9}lectionne le mod\u{00E8}le utilis\u{00E9} pour la conversation. Les mod\u{00E8}les plus gros sont plus lents mais plus capables."
            ))
        }
        .confirmationDialog(
            viewModel.localeManager.localizedString("Delete Model?", "Supprimer le mod\u{00E8}le?"),
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(viewModel.localeManager.localizedString("Delete", "Supprimer"), role: .destructive) {
                if let sourceID = viewModel.deleteTargetSourceID {
                    viewModel.deleteModel(sourceID)
                }
            }
            Button(viewModel.localeManager.localizedString("Cancel", "Annuler"), role: .cancel) {}
        } message: {
            Text(viewModel.localeManager.localizedString(
                "This will remove the AI model from your device. You'll need to download it again to use the assistant.",
                "Cela supprimera le mod\u{00E8}le IA de ton appareil. Tu devras le ret\u{00E9}l\u{00E9}charger pour utiliser l'assistant."
            ))
        }
    }

    @ViewBuilder
    private func chatModelStatus(for source: ModelSource) -> some View {
        let state = viewModel.modelDownloadManager.stateForSource(source.id)
        switch state {
        case .installed:
            Text(viewModel.localeManager.localizedString("Ready", "Pr\u{00EA}t"))
                .font(.caption2)
                .foregroundStyle(.green)
        case .installedMissingTokenizer:
            Text(viewModel.localeManager.localizedString("Missing Tokenizer", "Tokenizer manquant"))
                .font(.caption2)
                .foregroundStyle(.orange)
        case .downloading(let p):
            Text("\(Int(p * 100))%")
                .font(.caption2)
                .foregroundStyle(.tint)
        case .installing:
            ProgressView()
                .controlSize(.mini)
        case .unavailable:
            Text(viewModel.localeManager.localizedString("Unavailable", "Indisponible"))
                .font(.caption2)
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.red)
        case .notDownloaded:
            EmptyView()
        }
    }

    // MARK: - Embedding

    private var embeddingSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(viewModel.modelDownloadManager.selectedEmbeddingSource?.displayName ?? viewModel.localeManager.localizedString("Embedding Model", "Mod\u{00E8}le d'embeddings"))
                        .font(.body)
                    Text(viewModel.localeManager.localizedString("Semantic Memory / Recall", "M\u{00E9}moire s\u{00E9}mantique / Rappel"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modelStatusBadge(viewModel.modelDownloadManager.embeddingState)
            }

            if viewModel.modelDownloadManager.isEmbeddingReady {
                HStack {
                    Text(viewModel.localeManager.localizedString("Storage Used", "Espace utilis\u{00E9}"))
                    Spacer()
                    Text(viewModel.modelDownloadManager.embeddingStorageUsed)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    viewModel.deleteModel(viewModel.selectedEmbeddingSourceID)
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Delete Embedding Model", "Supprimer le mod\u{00E8}le d'embeddings"),
                        systemImage: "trash"
                    )
                }
            } else if viewModel.modelDownloadManager.embeddingState.isUnavailable {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(viewModel.localeManager.localizedString(
                        "Embedding model is optional. Chat works without semantic memory.",
                        "Le mod\u{00E8}le d'embeddings est optionnel. Le clavardage fonctionne sans m\u{00E9}moire s\u{00E9}mantique."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if !viewModel.modelDownloadManager.embeddingState.isDownloading && !viewModel.modelDownloadManager.embeddingState.isInstalling {
                let source = viewModel.modelDownloadManager.selectedEmbeddingSource
                if source?.isAvailableForDownload == true {
                    Button {
                        viewModel.downloadModel(viewModel.selectedEmbeddingSourceID)
                    } label: {
                        Label(
                            viewModel.localeManager.localizedString("Download Embedding Model", "T\u{00E9}l\u{00E9}charger le mod\u{00E8}le d'embeddings"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                }
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Embedding Model", "Mod\u{00E8}le d'embeddings"))
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            if let guidance = viewModel.runtimeAvailabilityGuidance {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        viewModel.localeManager.localizedString("Runtime Availability", "Disponibilit\u{00E9} du runtime"),
                        systemImage: "cpu"
                    )
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                    Text(viewModel.localizedRuntimeAvailabilityMessage(guidance))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(guidance.recoveryActions, id: \.rawValue) { action in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(viewModel.localizedRecoveryAction(action))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if guidance.recoveryActions.contains(.retryRuntimeLoad), let coordinator = viewModel.runtimeCoordinator {
                        Button {
                            coordinator.requestChatReloadForSelectionChange()
                        } label: {
                            Label(
                                viewModel.localeManager.localizedString("Retry Runtime Load", "R\u{00E9}essayer le chargement du runtime"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .font(.caption)
                        .accessibilityLabel(viewModel.localeManager.localizedString("Retry Runtime Load", "R\u{00E9}essayer le chargement du runtime"))
                        .accessibilityHint(viewModel.localeManager.localizedString(
                            "Reloads the selected chat model runtime now.",
                            "Recharge maintenant le runtime du mod\u{00E8}le de conversation s\u{00E9}lectionn\u{00E9}."
                        ))
                    }
                }
                .padding(.vertical, 4)
            }

            if let report = viewModel.chatModelLastFailure {
                modelFailureDiagnosticsRow(
                    title: viewModel.localeManager.localizedString("Chat Model Last Failure", "Dernier \u{00E9}chec du mod\u{00E8}le de conversation"),
                    report: report,
                    retryLabel: viewModel.localeManager.localizedString("Retry Chat Model Download", "R\u{00E9}essayer le t\u{00E9}l\u{00E9}chargement du mod\u{00E8}le de conversation"),
                    sourceID: viewModel.selectedChatSourceID
                )
            }

            if let report = viewModel.embeddingModelLastFailure {
                modelFailureDiagnosticsRow(
                    title: viewModel.localeManager.localizedString("Embedding Model Last Failure", "Dernier \u{00E9}chec du mod\u{00E8}le d'embeddings"),
                    report: report,
                    retryLabel: viewModel.localeManager.localizedString("Retry Embedding Download", "R\u{00E9}essayer le t\u{00E9}l\u{00E9}chargement des embeddings"),
                    sourceID: viewModel.selectedEmbeddingSourceID
                )
            }

            if !viewModel.hasDiagnostics {
                Text(viewModel.localeManager.localizedString(
                    "No recent model or runtime errors.",
                    "Aucune erreur r\u{00E9}cente du mod\u{00E8}le ou du runtime."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Diagnostics", "Diagnostics"))
        } footer: {
            Text(viewModel.localeManager.localizedString(
                "Actionable guidance is shown here for users. Detailed technical diagnostics remain in developer logs.",
                "Des conseils actionnables sont affich\u{00E9}s ici pour l'utilisateur. Les diagnostics techniques d\u{00E9}taill\u{00E9}s restent dans les journaux d\u{00E9}veloppeur."
            ))
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section {
            Toggle(
                viewModel.localeManager.localizedString("Offline Mode", "Mode hors ligne"),
                isOn: Bindable(viewModel.networkPolicy).offlineMode
            )

            if !viewModel.networkPolicy.offlineMode {
                Toggle(
                    viewModel.localeManager.localizedString("Allow Network Tools", "Autoriser les outils r\u{00E9}seau"),
                    isOn: Bindable(viewModel.networkPolicy).networkToolsEnabled
                )

                if viewModel.networkPolicy.networkToolsEnabled {
                    Toggle(
                        viewModel.localeManager.localizedString("Web Search", "Recherche Web"),
                        isOn: Bindable(viewModel.networkPolicy).allowWebSearch
                    )

                    Toggle(
                        viewModel.localeManager.localizedString("Weather", "M\u{00E9}t\u{00E9}o"),
                        isOn: Bindable(viewModel.networkPolicy).allowWeather
                    )

                    Toggle(
                        viewModel.localeManager.localizedString("Ask Before Network Use", "Demander avant d'utiliser le r\u{00E9}seau"),
                        isOn: Bindable(viewModel.networkPolicy).askBeforeNetworkUse
                    )
                }
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Network Tools", "Outils r\u{00E9}seau"))
        } footer: {
            Text(viewModel.localeManager.localizedString(
                "Core reasoning, memory, and voice always run on-device. Network tools are optional and require your permission.",
                "Le raisonnement, la m\u{00E9}moire et la voix fonctionnent toujours sur l'appareil. Les outils r\u{00E9}seau sont optionnels et n\u{00E9}cessitent ta permission."
            ))
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            HStack {
                Text(viewModel.localeManager.localizedString("Microphone", "Microphone"))
                Spacer()
                let micState = viewModel.permissionsManager.microphoneAuthorizationState
                Text(voicePermissionStatusText(micState))
                    .foregroundStyle(voicePermissionStatusColor(micState))
            }

            HStack {
                Text(viewModel.localeManager.localizedString("Speech Recognition", "Reconnaissance vocale"))
                Spacer()
                let speechState = viewModel.permissionsManager.speechRecognitionAuthorizationState
                Text(voicePermissionStatusText(speechState))
                    .foregroundStyle(voicePermissionStatusColor(speechState))
            }

            if viewModel.shouldShowVoiceSettingsRecovery {
                Text(viewModel.localeManager.localizedString(
                    "Voice permissions are currently denied. Open the app settings to enable microphone and speech recognition.",
                    "Les permissions vocales sont actuellement refusées. Ouvrez les réglages de l'app pour activer le microphone et la reconnaissance vocale."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    viewModel.openAppSettings()
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Open App Settings", "Ouvrir les réglages de l'app"),
                        systemImage: "arrow.up.forward.app"
                    )
                }
                .accessibilityLabel(viewModel.localeManager.localizedString("Open App Settings", "Ouvrir les réglages de l'app"))
                .accessibilityHint(viewModel.localeManager.localizedString(
                    "Opens iOS Settings for this app so you can enable microphone and speech recognition.",
                    "Ouvre les r\u{00E9}glages iOS de cette app pour activer le microphone et la reconnaissance vocale."
                ))
            } else if !viewModel.permissionsManager.canUseVoice {
                Button {
                    Task { await viewModel.requestVoicePermissions() }
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Grant Voice Permissions", "Accorder les permissions vocales"),
                        systemImage: "mic.badge.plus"
                    )
                }
                .accessibilityLabel(viewModel.localeManager.localizedString("Grant Voice Permissions", "Accorder les permissions vocales"))
                .accessibilityHint(viewModel.localeManager.localizedString(
                    "Requests microphone and speech recognition permissions if they were not requested yet.",
                    "Demande les permissions du microphone et de la reconnaissance vocale si elles n'ont pas encore \u{00E9}t\u{00E9} demand\u{00E9}es."
                ))
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Voice", "Voix"))
        }
    }

    // MARK: - Native Permissions

    private var nativePermissionsSection: some View {
        Section {
            ForEach(viewModel.permissionsManager.nativePermissionStatuses) { status in
                permissionStatusRow(
                    title: viewModel.permissionsManager.nativeFeatureTitle(status.feature, localeManager: viewModel.localeManager),
                    granted: status.granted
                )
            }

            if !viewModel.permissionsManager.allNativeFeaturePermissionsGranted {
                Button {
                    Task { await viewModel.requestAllNativeFeaturePermissions() }
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Grant All Native Permissions", "Accorder toutes les permissions natives"),
                        systemImage: "checkmark.shield"
                    )
                }
                .accessibilityLabel(viewModel.localeManager.localizedString("Grant All Native Permissions", "Accorder toutes les permissions natives"))
                .accessibilityHint(viewModel.localeManager.localizedString(
                    "Requests access to all native features used by MonGARS.",
                    "Demande l'acc\u{00E8}s \u{00E0} toutes les fonctionnalit\u{00E9}s natives utilis\u{00E9}es par MonGARS."
                ))
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Native Features", "Fonctionnalités natives"))
        } footer: {
            Text(viewModel.localeManager.localizedString(
                "Grant access to all built-in tools used by MonGARS (location, contacts, calendar, reminders, and notifications).",
                "Accorde l'accès à tous les outils natifs utilisés par MonGARS (localisation, contacts, calendrier, rappels et notifications)."
            ))
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.localeManager.localizedString("On-Device Processing", "Traitement sur l'appareil"))
                        .font(.body)
                    Text(viewModel.localeManager.localizedString(
                        "Core AI runs locally. Some optional tools may use the internet when enabled.",
                        "L'IA de base fonctionne localement. Certains outils optionnels peuvent utiliser Internet lorsqu'activ\u{00E9}s."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.localeManager.localizedString("No Data Collection", "Aucune collecte de donn\u{00E9}es"))
                        .font(.body)
                    Text(viewModel.localeManager.localizedString(
                        "Your conversations are never sent to any server",
                        "Tes conversations ne sont jamais envoy\u{00E9}es \u{00E0} un serveur"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Privacy", "Confidentialit\u{00E9}"))
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("monGARS")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(viewModel.localeManager.localizedString("About", "\u{00C0} propos"))
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func modelStatusBadge(_ state: ModelDownloadState) -> some View {
        switch state {
        case .installed:
            Text(viewModel.localeManager.localizedString("Ready", "Pr\u{00EA}t"))
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.green.opacity(0.15), in: Capsule())
        case .installedMissingTokenizer:
            Text(viewModel.localeManager.localizedString("Missing Tokenizer", "Tokenizer manquant"))
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
        case .downloading(let progress):
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.tint)
        case .installing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(viewModel.localeManager.localizedString("Installing", "Installation"))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        case .notDownloaded:
            Text(viewModel.localeManager.localizedString("Not Downloaded", "Non t\u{00E9}l\u{00E9}charg\u{00E9}"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable:
            Text(viewModel.localeManager.localizedString("Unavailable", "Indisponible"))
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func permissionStatusRow(title: String, granted: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted
                ? viewModel.localeManager.localizedString("Granted", "Accordé")
                : viewModel.localeManager.localizedString("Not Granted", "Non accordé"))
                .foregroundStyle(granted ? .green : .secondary)
        }
    }

    private func voicePermissionStatusText(_ state: PermissionsManager.VoiceAuthorizationState) -> String {
        switch state {
        case .granted:
            return viewModel.localeManager.localizedString("Granted", "Accordé")
        case .notDetermined:
            return viewModel.localeManager.localizedString("Not Requested", "Non demandé")
        case .denied:
            return viewModel.localeManager.localizedString("Denied", "Refusé")
        case .restricted:
            return viewModel.localeManager.localizedString("Restricted", "Restreint")
        }
    }

    private func voicePermissionStatusColor(_ state: PermissionsManager.VoiceAuthorizationState) -> Color {
        switch state {
        case .granted:
            return .green
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .secondary
        }
    }

    private func modelFailureDiagnosticsRow(
        title: String,
        report: ModelFailureReport,
        retryLabel: String,
        sourceID: ModelSourceID
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            HStack(spacing: 8) {
                Text(viewModel.localeManager.localizedString("Stage", "Étape"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(viewModel.localizedFailureStage(report.stage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(viewModel.localizedTimestamp(report.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(report.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(report.recoveryActions, id: \.rawValue) { action in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(viewModel.localizedRecoveryAction(action))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.modelDownloadManager.stateForSource(sourceID).isDownloading &&
                !viewModel.modelDownloadManager.stateForSource(sourceID).isInstalling {
                Button {
                    viewModel.downloadModel(sourceID)
                } label: {
                    Label(retryLabel, systemImage: "arrow.clockwise")
                }
                .font(.caption)
                .accessibilityLabel(retryLabel)
                .accessibilityHint(viewModel.localeManager.localizedString(
                    "Retries this model download using the current selection.",
                    "Relance le t\u{00E9}l\u{00E9}chargement de ce mod\u{00E8}le avec la s\u{00E9}lection actuelle."
                ))
            }
        }
        .padding(.vertical, 4)
    }
}
