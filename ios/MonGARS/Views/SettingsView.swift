import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            languageSection
            modelSection
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
                    Text(viewModel.localeManager.localizedString("Language Model", "Mod\u{00E8}le de langue"))
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

    private var privacySection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.localeManager.localizedString("On-Device Processing", "Traitement sur l'appareil"))
                        .font(.body)
                    Text(viewModel.localeManager.localizedString(
                        "All AI processing happens locally on your device",
                        "Tout le traitement IA se fait localement sur ton appareil"
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
                        "Your conversations are never sent anywhere",
                        "Tes conversations ne sont jamais envoy\u{00E9}es nulle part"
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
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}
