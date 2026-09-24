import SwiftUI

/// OpenAI-compatible endpoint connection, credential, and model controls.
/// These members are internal because Swift extensions in separate files cannot share lexical `private` access;
/// the owning view itself remains module-internal.
extension EngineAndModelPaneView {
// MARK: - OpenAI-compatible endpoint

    /// Endpoint controls stay inside the unified engine pane. The connection model owns network
    /// state, the settings model owns durable non-secret values, and the API key draft only lives
    /// for this view's lifetime before an explicit Connect saves it to Keychain.
    @ViewBuilder
    var openAICompatibleSections: some View {
        Section("Connection") {
            Picker(selection: endpointProviderBinding) {
                ForEach(OpenAICompatibleProviderPreset.allCases) { provider in
                    Text(provider.displayLabel).tag(provider)
                }
            } label: {
                SettingsRowLabel(
                    title: "Provider",
                    description: "Groq runs open models in the cloud at very high speed. Custom Server " +
                        "talks to Ollama, LM Studio, vLLM, or any OpenAI-compatible address.",
                    systemImage: "server.rack"
                )
            }
            .pickerStyle(.segmented)
            .settingsItem(.endpointProvider)

            if suggestionSettings.endpointProvider == .groq {
                groqConnectionRow
            } else {
                customServerConnectionRow
            }

            endpointAPIKeyRow

            if let warning = endpointPrivacyWarning {
                SettingsCalloutView(callout: SettingsPaneCallout(tone: .warning, message: warning))
            }
            if let endpointCredentialError {
                SettingsCalloutView(
                    callout: SettingsPaneCallout(tone: .warning, message: endpointCredentialError)
                )
            }
        }

        endpointModelSection
    }

    private var groqConnectionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRowLabel(
                title: "Groq",
                description: "Requests go to \(OpenAICompatibleProviderPreset.groqBaseURLString). " +
                    "Paste an API key below, then Connect to load the model list.",
                systemImage: "bolt.horizontal"
            )

            HStack(spacing: 8) {
                endpointConnectionStatus

                Spacer(minLength: 8)

                if let keyURL = URL(string: OpenAICompatibleProviderPreset.groqAPIKeyURLString) {
                    Link("Get a key", destination: keyURL)
                }

                Button(endpointConnectButtonTitle, action: refreshEndpointModels)
                    .buttonStyle(.borderedProminent)
                    .disabled(openAICompatibleConnectionModel.state == .connecting)
            }
        }
    }

    private var customServerConnectionRow: some View {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRowLabel(
                    title: "Server URL",
                    description: "The OpenAI-compatible server address. Cotabby adds /v1 when the " +
                        "address has no path; Ollama uses http://127.0.0.1:11434 by default.",
                    systemImage: "network"
                )

                HStack(spacing: 8) {
                    TextField(
                        "",
                        text: endpointBaseURLBinding,
                        prompt: Text(OpenAICompatibleEndpointConfiguration.defaultBaseURLString)
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(refreshEndpointModels)

                    Button(
                        endpointConnectButtonTitle,
                        action: refreshEndpointModels
                    )
                    .buttonStyle(.borderedProminent)
                    .disabled(openAICompatibleConnectionModel.state == .connecting)
                }

                HStack(spacing: 8) {
                    endpointConnectionStatus

                    Spacer(minLength: 8)

                    Button("Use Ollama Default", systemImage: "arrow.counterclockwise") {
                        resetEndpointBaseURL()
                    }
                    .disabled(
                        suggestionSettings.openAICompatibleBaseURL
                            == OpenAICompatibleEndpointConfiguration.defaultBaseURLString
                    )
                }
            }
            .settingsItem(.endpointBaseURL)
    }

    private var endpointAPIKeyRow: some View {
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("", text: $endpointAPIKeyDraft, prompt: Text("Paste API key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 300)

                    if !endpointAPIKeyDraft.isEmpty {
                        Button("Clear") {
                            endpointAPIKeyDraft = ""
                            do {
                                try suggestionSettings.saveOpenAICompatibleAPIKey(nil)
                                endpointCredentialError = nil
                            } catch {
                                endpointCredentialError = error.localizedDescription
                            }
                        }
                    }
                }
            } label: {
                SettingsRowLabel(
                    title: "API Key",
                    description: suggestionSettings.endpointProvider == .groq
                        ? "Your Groq key, stored in Keychain separately from the custom server's token."
                        : "Optional bearer token stored in Keychain. Ollama does not require one.",
                    systemImage: "key"
                )
            }
            .settingsItem(.endpointAPIKey)
    }

    @ViewBuilder
    private var endpointModelSection: some View {
        Section("Model") {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("", text: endpointModelBinding, prompt: Text("Enter model identifier"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)

                    Menu {
                        ForEach(openAICompatibleConnectionModel.models) { model in
                            Button(model.id) {
                                suggestionSettings.setActiveEndpointModelName(model.id)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(openAICompatibleConnectionModel.models.isEmpty)
                    .help(endpointModelMenuHelp)
                    .accessibilityLabel("Choose a discovered model")
                }
            } label: {
                SettingsRowLabel(
                    title: "Model",
                    description: suggestionSettings.endpointProvider == .groq
                        ? "\(OpenAICompatibleProviderPreset.groqDefaultModelName) is the fastest option. " +
                            "Larger models are smarter but add latency."
                        : "Choose a model returned by the server or enter its identifier manually.",
                    systemImage: "shippingbox"
                )
            }
            .settingsItem(.endpointModel)

            if suggestionSettings.endpointProvider == .custom {
                endpointAPIModePicker
            } else {
                groqThroughputControls
            }
        }
    }

    /// Groq is fast enough to read far more of the document per keystroke, but the free tier's
    /// token allowance is tiny, so the plan picker also switches Cotabby to word-boundary requests.
    @ViewBuilder
    private var groqThroughputControls: some View {
        Toggle(isOn: Binding(
            get: { suggestionSettings.isLargeEndpointContextEnabled },
            set: { suggestionSettings.setLargeEndpointContextEnabled($0) }
        )) {
            SettingsRowLabel(
                title: "Large Context",
                description: "Sends up to about 7,500 characters before the caret and 600 after it. " +
                    "Turn off to send about 4,000 and use fewer tokens.",
                systemImage: "text.alignleft"
            )
        }
        .settingsItem(.endpointContextSize)

        Picker(selection: Binding(
            get: { suggestionSettings.endpointTokensPerMinuteBudget },
            set: { suggestionSettings.setEndpointTokensPerMinuteBudget($0) }
        )) {
            Text("Developer").tag(SuggestionSettingsStore.defaultEndpointTokensPerMinuteBudget)
            Text("Free").tag(SuggestionSettingsStore.freeTierEndpointTokensPerMinuteBudget)
        } label: {
            SettingsRowLabel(
                title: "Groq Plan",
                description: "Matches Cotabby's request pace to your Groq limits. Free (8k tokens per minute) " +
                    "only asks at word boundaries; Developer (250k) suggests on every pause.",
                systemImage: "gauge.with.dots.needle.33percent"
            )
        }
        .pickerStyle(.segmented)
        .settingsItem(.endpointRateBudget)
    }

    private var endpointAPIModePicker: some View {
            Picker(selection: endpointAPIModeBinding) {
                Text("Chat Completions").tag(OpenAICompatibleAPIMode.chatCompletions)
                Text("Text Completions").tag(OpenAICompatibleAPIMode.completions)
            } label: {
                SettingsRowLabel(
                    title: "API Format",
                    description: "Chat uses /v1/chat/completions (recommended). Text uses " +
                        "/v1/completions for base models that continue a raw prompt.",
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .pickerStyle(.segmented)
            .settingsItem(.endpointAPIMode)
    }

    @ViewBuilder
    func installedModelRow(_ model: RuntimeModelOption) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)

                if model.displayName != model.actualModelName {
                    Text(model.actualModelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if model.filename == runtimeModel.selectedModelFilename {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else if modelDownloadManager.canDeleteModel(filename: model.filename) {
                Button {
                    pendingDeletionModel = model
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
