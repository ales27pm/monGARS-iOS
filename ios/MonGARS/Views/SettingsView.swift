import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            languageSection
            modelSection
            embeddingSection
            networkSection
            voiceSection
            privacySection
            aboutSection
        }
        .navigationTitle(viewModel.localeManager.localizedString("Settings", "R\u{00E9}glages"))
    }

    private var languageSection: some View {
        Section {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    viewModel.selectedLanguage = language
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(language.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
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

    private var modelSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(viewModel.modelDownloadManager.selectedLLMVariant.displayName)
                        .font(.body)
                    Text(viewModel.localeManager.localizedString("Language Model — Conversation", "Mod\u{00E8}le de langue — Conversation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modelStatusBadge(viewModel.modelDownloadManager.llmState)
            }

            if viewModel.modelDownloadManager.isLLMReady {
                HStack {
                    Text(viewModel.localeManager.localizedString("Storage Used", "Espace utilis\u{00E9}"))
                    Spacer()
                    Text(viewModel.modelDownloadManager.llmStorageUsed)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    viewModel.showDeleteConfirmation = true
                    viewModel.modelToDelete = viewModel.modelDownloadManager.selectedLLMVariant
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Delete Model", "Supprimer le mod\u{00E8}le"),
                        systemImage: "trash"
                    )
                }
            } else if !viewModel.modelDownloadManager.llmState.isDownloading && !viewModel.modelDownloadManager.llmState.isInstalling {
                Button {
                    viewModel.downloadModel(viewModel.modelDownloadManager.selectedLLMVariant)
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Download Model", "T\u{00E9}l\u{00E9}charger le mod\u{00E8}le"),
                        systemImage: "arrow.down.circle"
                    )
                }
            }
        } header: {
            Text(viewModel.localeManager.localizedString("AI Model", "Mod\u{00E8}le IA"))
        }
        .confirmationDialog(
            viewModel.localeManager.localizedString("Delete Model?", "Supprimer le mod\u{00E8}le?"),
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(viewModel.localeManager.localizedString("Delete", "Supprimer"), role: .destructive) {
                if let variant = viewModel.modelToDelete {
                    viewModel.deleteModel(variant)
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

    private var embeddingSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(ModelVariant.graniteEmbedding.displayName)
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
                    viewModel.modelDownloadManager.deleteModel(variant: .graniteEmbedding)
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
                        "Requires a CoreML-converted embedding model. Chat works without it.",
                        "N\u{00E9}cessite un mod\u{00E8}le d'embeddings converti en CoreML. Le clavardage fonctionne sans."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Embedding Model", "Mod\u{00E8}le d'embeddings"))
        }
    }

    private var voiceSection: some View {
        Section {
            HStack {
                Text(viewModel.localeManager.localizedString("Microphone", "Microphone"))
                Spacer()
                Text(viewModel.permissionsManager.microphoneGranted
                     ? viewModel.localeManager.localizedString("Granted", "Accord\u{00E9}")
                     : viewModel.localeManager.localizedString("Not Granted", "Non accord\u{00E9}"))
                    .foregroundStyle(viewModel.permissionsManager.microphoneGranted ? .green : .secondary)
            }

            HStack {
                Text(viewModel.localeManager.localizedString("Speech Recognition", "Reconnaissance vocale"))
                Spacer()
                Text(viewModel.permissionsManager.speechRecognitionGranted
                     ? viewModel.localeManager.localizedString("Granted", "Accord\u{00E9}")
                     : viewModel.localeManager.localizedString("Not Granted", "Non accord\u{00E9}"))
                    .foregroundStyle(viewModel.permissionsManager.speechRecognitionGranted ? .green : .secondary)
            }

            if !viewModel.permissionsManager.canUseVoice {
                Button {
                    Task { await viewModel.requestVoicePermissions() }
                } label: {
                    Label(
                        viewModel.localeManager.localizedString("Grant Voice Permissions", "Accorder les permissions vocales"),
                        systemImage: "mic.badge.plus"
                    )
                }
            }
        } header: {
            Text(viewModel.localeManager.localizedString("Voice", "Voix"))
        }
    }

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
}
