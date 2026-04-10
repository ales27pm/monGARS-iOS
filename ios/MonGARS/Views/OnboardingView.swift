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
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: viewModel.isDownloading)

            VStack(spacing: 12) {
                Text(viewModel.localeManager.localizedString("Download AI Model", "T\u{00E9}l\u{00E9}charger le mod\u{00E8}le IA"))
                    .font(.title.bold())

                Text(viewModel.localeManager.localizedString(
                    "The AI model needs to be downloaded once to run on your device. This requires approximately \(viewModel.modelDownloadManager.selectedLLMVariant.estimatedSizeDescription) of storage.",
                    "Le mod\u{00E8}le IA doit \u{00EA}tre t\u{00E9}l\u{00E9}charg\u{00E9} une fois pour fonctionner sur ton appareil. Cela n\u{00E9}cessite environ \(viewModel.modelDownloadManager.selectedLLMVariant.estimatedSizeDescription) d'espace."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }

            VStack(spacing: 16) {
                HStack {
                    Text(viewModel.modelDownloadManager.selectedLLMVariant.displayName)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(viewModel.modelDownloadManager.selectedLLMVariant.estimatedSizeDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                switch viewModel.modelDownloadManager.llmState {
                case .notDownloaded:
                    EmptyView()
                case .downloading(let progress):
                    VStack(spacing: 8) {
                        ProgressView(value: progress)
                            .tint(Color.accentColor)
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .paused(let progress):
                    VStack(spacing: 8) {
                        ProgressView(value: progress)
                            .tint(.orange)
                        Text(viewModel.localeManager.localizedString("Paused", "En pause"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                case .downloaded:
                    Label(
                        viewModel.localeManager.localizedString("Downloaded", "T\u{00E9}l\u{00E9}charg\u{00E9}"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.subheadline)
                case .error(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                if viewModel.isModelReady {
                    Button {
                        viewModel.advanceStep()
                    } label: {
                        Text(viewModel.localeManager.localizedString("Continue", "Continuer"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if viewModel.isDownloading {
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
                        Text(viewModel.localeManager.localizedString("Download Model", "T\u{00E9}l\u{00E9}charger le mod\u{00E8}le"))
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

                Text(viewModel.localeManager.localizedString(
                    "monGARS is ready to assist you. Start a conversation to begin.",
                    "monGARS est pr\u{00EA}t \u{00E0} t'aider. Commence une conversation."
                ))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
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
