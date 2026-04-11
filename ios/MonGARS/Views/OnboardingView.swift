import SwiftUI

struct OnboardingView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        TabView(selection: Bindable(viewModel).currentStep) {
            welcomeStep
                .tag(OnboardingStep.welcome)
            privacyStep
                .tag(OnboardingStep.privacy)
            languageStep
                .tag(OnboardingStep.language)
            modelDownloadStep
                .tag(OnboardingStep.modelDownload)
            completeStep
                .tag(OnboardingStep.complete)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .animation(.spring(duration: 0.4), value: viewModel.currentStep)
        .ignoresSafeArea()
    }

    private var welcomeStep: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 12) {
                Text("monGARS")
                    .font(.largeTitle.bold())

                Text(viewModel.localeManager.localizedString(
                    "Your on-device AI assistant",
                    "Ton assistant IA sur appareil"
                ))
                .font(.title3)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                featureRow(icon: "lock.shield", title: viewModel.localeManager.localizedString("Private by Design", "Priv\u{00E9} par conception"), subtitle: viewModel.localeManager.localizedString("Everything runs on your device", "Tout fonctionne sur ton appareil"))
                featureRow(icon: "globe.americas", title: viewModel.localeManager.localizedString("Bilingual", "Bilingue"), subtitle: viewModel.localeManager.localizedString("English & French (Canada)", "Anglais et fran\u{00E7}ais (Canada)"))
                featureRow(icon: "bolt.fill", title: viewModel.localeManager.localizedString("Intelligent", "Intelligent"), subtitle: viewModel.localeManager.localizedString("Powered by on-device AI", "Propuls\u{00E9} par l'IA locale"))
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                viewModel.advanceStep()
            } label: {
                Text(viewModel.localeManager.localizedString("Get Started", "Commencer"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    private var privacyStep: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            VStack(spacing: 12) {
                Text(viewModel.localeManager.localizedString("Privacy First", "Vie priv\u{00E9}e d'abord"))
                    .font(.title.bold())

                Text(viewModel.localeManager.localizedString(
                    "monGARS runs entirely on your iPhone. Your conversations, voice, and data never leave your device. No cloud. No tracking. No data collection.",
                    "monGARS fonctionne enti\u{00E8}rement sur ton iPhone. Tes conversations, ta voix et tes donn\u{00E9}es ne quittent jamais ton appareil. Pas de nuage. Pas de suivi. Pas de collecte de donn\u{00E9}es."
                ))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }

            VStack(alignment: .leading, spacing: 12) {
                privacyItem(icon: "iphone", text: viewModel.localeManager.localizedString("AI model runs locally", "Le mod\u{00E8}le IA fonctionne localement"))
                privacyItem(icon: "externaldrive", text: viewModel.localeManager.localizedString("Data stored on device only", "Donn\u{00E9}es stock\u{00E9}es sur l'appareil seulement"))
                privacyItem(icon: "hand.raised", text: viewModel.localeManager.localizedString("No telemetry or analytics", "Aucune t\u{00E9}l\u{00E9}m\u{00E9}trie ni analytique"))
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                viewModel.advanceStep()
            } label: {
                Text(viewModel.localeManager.localizedString("Continue", "Continuer"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    private var languageStep: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "globe.americas.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            VStack(spacing: 12) {
                Text(viewModel.localeManager.localizedString("Choose Your Language", "Choisis ta langue"))
                    .font(.title.bold())

                Text(viewModel.localeManager.localizedString(
                    "You can change this anytime in Settings.",
                    "Tu peux changer cela \u{00E0} tout moment dans les R\u{00E9}glages."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        viewModel.localeManager.currentLanguage = language
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(language.displayName)
                                    .font(.headline)
                                Text(language == .englishCA ? "English (Canada)" : "Canadian French")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if viewModel.localeManager.currentLanguage == language {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .font(.title3)
                            }
                        }
                        .padding()
                        .background(
                            viewModel.localeManager.currentLanguage == language
                                ? AnyShapeStyle(Color.accentColor.opacity(0.1))
                                : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                            in: .rect(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                viewModel.advanceStep()
            } label: {
                Text(viewModel.localeManager.localizedString("Continue", "Continuer"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    private var modelDownloadStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: viewModel.isAnyDownloadActive)

                VStack(spacing: 8) {
                    Text(viewModel.localeManager.localizedString("Download AI Models", "T\u{00E9}l\u{00E9}charger les mod\u{00E8}les IA"))
                        .font(.title2.bold())

                    Text(viewModel.localeManager.localizedString(
                        "The AI models need to be downloaded once to run on your device.",
                        "Les mod\u{00E8}les IA doivent \u{00EA}tre t\u{00E9}l\u{00E9}charg\u{00E9}s une fois pour fonctionner sur ton appareil."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                }

                llmModelCard
                embeddingModelCard

                if let overall = viewModel.overallPhaseDescription {
                    Text(overall)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .padding(.top, 4)
                }

                Spacer().frame(height: 16)

                VStack(spacing: 12) {
                    if viewModel.isChatReady {
                        Button {
                            viewModel.advanceStep()
                        } label: {
                            Text(viewModel.localeManager.localizedString("Continue", "Continuer"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if viewModel.isAnyDownloadActive {
                        Button {
                            viewModel.cancelDownload()
                        } label: {
                            Text(viewModel.localeManager.localizedString("Cancel Download", "Annuler le t\u{00E9}l\u{00E9}chargement"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Button {
                            viewModel.startDownload()
                        } label: {
                            Text(viewModel.localeManager.localizedString("Download Models", "T\u{00E9}l\u{00E9}charger les mod\u{00E8}les"))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    Button {
                        viewModel.skipToComplete()
                    } label: {
                        Text(viewModel.localeManager.localizedString("Skip for Now", "Passer pour l'instant"))
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var llmModelCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.modelDownloadManager.selectedLLMVariant.displayName)
                        .font(.subheadline.bold())
                    Text(viewModel.localeManager.localizedString("Conversation", "Conversation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(viewModel.modelDownloadManager.selectedLLMVariant.estimatedSizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            modelStateView(
                state: viewModel.modelDownloadManager.llmState,
                progress: viewModel.llmProgress,
                isInstalling: viewModel.isLLMInstalling
            )
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private var embeddingModelCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ModelVariant.graniteEmbedding.displayName)
                        .font(.subheadline.bold())
                    Text(viewModel.localeManager.localizedString("Semantic Memory / Recall", "M\u{00E9}moire s\u{00E9}mantique / Rappel"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(ModelVariant.graniteEmbedding.estimatedSizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            modelStateView(
                state: viewModel.modelDownloadManager.embeddingState,
                progress: viewModel.embeddingProgress,
                isInstalling: viewModel.isEmbeddingInstalling
            )

            if viewModel.isEmbeddingUnavailable {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text(viewModel.localeManager.localizedString(
                        "Semantic memory will be available once a CoreML embedding model is configured.",
                        "La m\u{00E9}moire s\u{00E9}mantique sera disponible d\u{00E8}s qu'un mod\u{00E8}le d'embeddings CoreML sera configur\u{00E9}."
                    ))
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func modelStateView(state: ModelDownloadState, progress: Double, isInstalling: Bool) -> some View {
        switch state {
        case .notDownloaded:
            EmptyView()
        case .downloading(let p):
            VStack(spacing: 6) {
                ProgressView(value: p)
                    .tint(Color.accentColor)
                Text("\(Int(p * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installing:
            VStack(spacing: 6) {
                ProgressView()
                if let phase = viewModel.installPhaseDescription {
                    Text(phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .installed:
            Label(
                viewModel.localeManager.localizedString("Installed", "Install\u{00E9}"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.subheadline)
        case .unavailable(let reason):
            Label {
                Text(viewModel.localeManager.localizedString("Not yet available", "Pas encore disponible"))
                    .font(.caption)
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(.orange)
        case .error(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Label(viewModel.localeManager.localizedString("Error", "Erreur"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption.bold())
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(4)
            }
        }
    }

    private var completeStep: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .symbolEffect(.bounce)

            VStack(spacing: 12) {
                Text(viewModel.localeManager.localizedString("You're All Set!", "C'est pr\u{00EA}t!"))
                    .font(.title.bold())

                if viewModel.isChatReady && !viewModel.isEmbeddingReady {
                    Text(viewModel.localeManager.localizedString(
                        "Chat is ready. Semantic memory will be available once the embedding model is installed.",
                        "Le clavardage est pr\u{00EA}t. La m\u{00E9}moire s\u{00E9}mantique sera disponible une fois le mod\u{00E8}le d'embeddings install\u{00E9}."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                } else {
                    Text(viewModel.localeManager.localizedString(
                        "monGARS is ready to assist you. Start a conversation to begin.",
                        "monGARS est pr\u{00EA}t \u{00E0} t'aider. Commence une conversation."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                }
            }

            Spacer()

            Button {
                viewModel.advanceStep()
            } label: {
                Text(viewModel.localeManager.localizedString("Start Chatting", "Commencer \u{00E0} discuter"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func privacyItem(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.green)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}
