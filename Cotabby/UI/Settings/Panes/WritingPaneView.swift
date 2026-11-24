import SwiftUI

/// File overview:
/// "Writing" detail pane of the redesigned Settings window. Owns how the completion reads:
/// preferred length, profile (display name), preferred response languages, and the user's custom
/// style rules.
struct WritingPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @ObservedObject var jevKeyModel: JevKeyModel
    let clearLearnedPhrases: () -> Void
    let correctionJournal: CorrectionJournal
    let trainingLog: TrainingLog
    @AppStorage(CorrectionJournal.enabledDefaultsKey) private var keepsJournal = true
    @AppStorage(WordPredictionController.enabledDefaultsKey) private var wordPredictionsEnabled = true
    @AppStorage(PersonalPhraseModel.learningDefaultsKey) private var learnsPhrases = true
    @State private var clearedLearnedPhrases = false
    @StateObject private var systemAutocorrect = SystemAutocorrectModel()
    @State private var jevKeyDraft = ""

    var body: some View {
        SettingsPaneScaffold {
            Section("Length") {
                Picker(selection: lengthChoiceBinding) {
                    ForEach(SuggestionWordCountPreset.allCases) { preset in
                        Text(preset.displayLabel).tag(LengthChoice.preset(preset))
                    }
                    Text("Custom range…").tag(LengthChoice.custom)
                } label: {
                    SettingsRowLabel(
                        title: "Length",
                        description: "How many words Cotabby aims for per suggestion. Shorter is snappier; " +
                            "longer covers more thoughts but takes longer to generate.",
                        systemImage: "ruler"
                    )
                }
                .settingsItem(.length)

                // Min and Max are editable while Custom is active: type a value or nudge it with the
                // arrows. Both rows commit through `setCustomWordCountRange`, which clamps to
                // [minimumWord, maximumWord] and keeps Max >= Min, so neither a typed nor a stepped
                // value can leave the sensible range. Stacked as their own rows (rather than the old
                // side-by-side steppers) so each reads as one editable field. Shown only in Custom so
                // the curated picker stays the common path.
                if suggestionSettings.isUsingCustomWordCountRange {
                    LabeledContent("Minimum") {
                        wordCountField(value: customLowBinding, label: "Minimum word count")
                    }
                    LabeledContent("Maximum") {
                        wordCountField(value: customHighBinding, label: "Maximum word count")
                    }
                    Text("Token budget scales by your selected language. Multiple languages or a " +
                        "language Cotabby doesn't recognize use the English ratio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // What an accept inserts beyond the bare word. These shape the written output, so they sit
            // with Writing rather than General; the accept keys themselves live in the Shortcuts pane.
            Section("Acceptance") {
                Toggle(isOn: autoAcceptTrailingPunctuationBinding) {
                    SettingsRowLabel(
                        title: "Accept Punctuation With Word",
                        description: "When you accept a word, also accept the punctuation that follows it " +
                            "(commas, periods) so you don't have to type it.",
                        systemImage: "textformat.abc"
                    )
                }
                .settingsItem(.acceptPunctuation)

                Toggle(isOn: addSpaceAfterAcceptBinding) {
                    SettingsRowLabel(
                        title: "Add Space After Accepting",
                        description: "When accepting a suggestion finishes a word, also add a space so you can " +
                            "keep typing. Skipped when it already ends in punctuation or a space.",
                        systemImage: "space"
                    )
                }
                .settingsItem(.addSpaceAfterAccept)
            }

            // Typo handling is a dependency chain, so the UI discloses it progressively rather than
            // showing every control at once. The master gate ("Hide Suggestions on Typo") detects
            // misspellings; the correction actions only function while it is on; the dictionaries
            // only matter once an action can consume them. Revealing each level when it becomes
            // relevant — instead of dimming dependents in place — makes the hierarchy unmistakable:
            // turning the gate off removes the controls that depend on it. This is the established
            // master/dependent idiom in this app (see `EmojiPaneView`). The earlier flat layout put
            // all three toggles at the same visual level, so it was not obvious the gate governed the
            // other two.
            Section("Word Predictions") {
                Toggle(isOn: $wordPredictionsEnabled) {
                    SettingsRowLabel(
                        title: "Show Next-Word Predictions",
                        description: "A strip of up to five likely words appears above the caret as you type. Tab " +
                            "types the first word and the next word is predicted right away, so you can build a " +
                            "sentence by pressing Tab. Option-2 to 5 type the others. Return and Escape work as usual. " +
                            "While this is on it replaces ghost-text suggestions, and a misspelled word's fix bar " +
                            "comes first. The words are ordered by a language model that reads your last few " +
                            "sentences, so the verb form offered follows the tense you are writing in. " +
                            "Runs entirely on this Mac.",
                        systemImage: "text.word.spacing"
                    )
                }
                // Not disabled with the toggle above: the same two choices also set the look of the
                // spelling bar and the sentence cards, which show whether or not the strip is on.
                PanelAppearanceRows()
                Toggle(isOn: $learnsPhrases) {
                    SettingsRowLabel(
                        title: "Learn From My Sentences",
                        description: "Remembers the words and word sequences of sentences you finish, so your own " +
                            "vocabulary and phrasing are predicted first, and lets the word model read your last few " +
                            "sentences. Stored only on this Mac. A spelling it does not know is never learned. " +
                            "Nothing new is learned from your sentences while Show Next-Word Predictions is off; " +
                            "what was learned before is kept until you clear it below.",
                        systemImage: "brain"
                    )
                }
                // Greyed out with the strip, and off with it too: the learner reads both switches
                // (`PersonalPhraseModel.isLearningEnabled`), so this one cannot sit greyed out and
                // showing "on" while sentences are still being learned.
                .disabled(!wordPredictionsEnabled)
                Toggle(isOn: $keepsJournal) {
                    SettingsRowLabel(
                        title: "Keep a Correction Journal",
                        description: "Records only misspelled words and what they became (auto-fixed, picked, undone, or " +
                            "fixed by you), never other text or password fields, so fixes can be tuned to your " +
                            "mistakes. Stored only on this Mac. The journal is only the record: the fixes you accept " +
                            "or make yourself are remembered and applied next time whether or not it is on. Clear " +
                            "Journal deletes this file and nothing else. Clear Learned Words, Phrases and Fixes makes " +
                            "Cotabby forget everything it learned from you: those fixes, the words you chose to keep as " +
                            "typed, your own words and phrases, and the recent sentences the word model reads. It " +
                            "leaves the journal and saved training examples, which have their own buttons.",
                        systemImage: "book.closed"
                    )
                }
                HStack {
                    Button("Show Journal in Finder") {
                        if let url = correctionJournal.fileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Button("Clear Journal") { correctionJournal.clear() }
                }
                // The label lists what is forgotten because the button has no description row of its
                // own: learned words and phrases (with the recent sentences the word model reads),
                // and the fixes the writer accepted or declined. The journal and the training record
                // are files with their own delete buttons and are left alone.
                Button(clearedLearnedPhrases ? "Cleared" : "Clear Learned Words, Phrases and Fixes") {
                    clearLearnedPhrases()
                    clearedLearnedPhrases = true
                }
                .disabled(clearedLearnedPhrases)
            }

            TrainingDataSection(trainingLog: trainingLog)

            Section("Typos") {
                Toggle(isOn: suppressCompletionsOnTypoBinding) {
                    SettingsRowLabel(
                        title: "Hide Suggestions on Typo",
                        description: "Pauses normal completions while the current word looks misspelled. " +
                            "Turn this on to use the correction options.",
                        systemImage: "eye.slash"
                    )
                }
                .settingsItem(.hideSuggestionsOnTypo)
            }

            if suggestionSettings.suppressCompletionsOnTypo {
                Section("Corrections") {
                    Toggle(isOn: offerTypoCorrectionsBinding) {
                        SettingsRowLabel(
                            title: "Offer Corrections on Typo",
                            description: "Shows a green replacement you can apply with your accept key.",
                            systemImage: "checkmark.bubble"
                        )
                    }
                    .settingsItem(.offerTypoCorrections)

                    Toggle(isOn: automaticallyFixTyposBinding) {
                        SettingsRowLabel(
                            title: "Automatically Fix Confident Typos",
                            description: "After you press Space, fixes a word when Cotabby is sure. Otherwise a bar opens " +
                                "above the word: your word, then up to three fixes. Tab takes the best fix, Option-1 to 4 " +
                                "pick any slot, arrows move the highlight.",
                            systemImage: "checkmark.circle"
                        )
                    }
                    .settingsItem(.automaticallyFixTypos)

                    Toggle(isOn: sentenceCheckBinding) {
                        SettingsRowLabel(
                            title: "Check Finished Sentences",
                            description: "Rereads each sentence when you finish it or pause in it, and fixes or offers what " +
                                "the word-by-word check cannot see (a doubled word, their/there, a misspelled name). " +
                                "Off by default: it runs a second model.",
                            systemImage: "text.badge.checkmark"
                        )
                    }
                    .settingsItem(.sentenceCheck)
                }

                Section("macOS Autocorrect") {
                    if systemAutocorrect.isSystemAutocorrectOn {
                        SettingsRowLabel(
                            title: "macOS Autocorrect Is Also On",
                            description: "macOS and Cotabby both fix words as you type, so they fight over the same word: a fix can "
                                + "flip back or lose its space. Cotabby covers what macOS does, so turning the macOS one off is "
                                + "recommended. Apps pick up the change when reopened.",
                            systemImage: "exclamationmark.triangle"
                        )
                        Button("Turn Off macOS Autocorrect and Auto-Capitalize") { systemAutocorrect.turnOff() }
                    } else {
                        SettingsRowLabel(
                            title: "Cotabby Handles Corrections",
                            description: "macOS autocorrect and auto-capitalize are off, so only Cotabby fixes words.",
                            systemImage: "checkmark.seal"
                        )
                        if systemAutocorrect.canRestore {
                            Button("Restore macOS Settings") { systemAutocorrect.restore() }
                        }
                    }
                }
                .onAppear { systemAutocorrect.refresh() }

                Section("Word Intent (Jev)") {
                    SettingsRowLabel(
                        title: "Read the Sentence for Unclear Words",
                        description: "Corrections are local and instant. With a TypeSafe Jev key, words Cotabby " +
                            "can't settle alone (wich: which or with?) and slips like went their are re-ranked by " +
                            "reading the whole sentence, usually in under half a second. Confident fixes never use Jev.",
                        systemImage: "sparkles"
                    )
                    HStack {
                        SecureField(jevKeyModel.hasKey ? "Key saved in Keychain" : "TypeSafe API key", text: $jevKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            jevKeyModel.save(jevKeyDraft)
                            jevKeyDraft = ""
                        }
                        .disabled(jevKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if jevKeyModel.hasKey {
                            Button("Test") { jevKeyModel.test() }
                                .disabled(jevKeyModel.isTesting)
                            Button("Remove", role: .destructive) { jevKeyModel.remove() }
                        }
                    }
                    if let status = jevKeyModel.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Link("Get a key at typesafe.ai", destination: URL(string: "https://typesafe.ai")!)
                        .font(.caption)
                }

                // Dictionaries rank candidates for the two correction actions above, so they only
                // appear once at least one action is on. With neither active, choosing a dictionary
                // would have no observable effect.
                if suggestionSettings.offerTypoCorrections || suggestionSettings.automaticallyFixTypos {
                    Section("Spelling Dictionaries") {
                        SpellingDictionaryPicker(suggestionSettings: suggestionSettings)
                            .settingsItem(.spellingDictionaries)
                    }
                }
            }

            Section("Profile") {
                VStack(alignment: .leading, spacing: 16) {
                    // Introduces the personalization inputs passed to the AI. The custom-rules input
                    // is gated (CustomRulesCatalog.isUserFacingEnabled), so this copy and the Rules
                    // section below are dropped together while the feature is hidden.
                    Text(CustomRulesCatalog.isUserFacingEnabled
                        ? "Your name, languages, and rules are passed to the AI to help personalize your completions."
                        : "Your name and languages are passed to the AI to help personalize your completions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name")
                            .font(.system(size: 13, weight: .medium))

                        TextField("What should Cotabby call you?", text: Binding(
                            get: { suggestionSettings.userName },
                            set: { suggestionSettings.setUserName($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.vertical, 6)
                .settingsItem(.name)
            }

            // The editors suppress their own titles here so the Section headers ("Languages"/"Rules")
            // carry the heading, matching the explicit-header pattern used across the pane.
            Section("Languages") {
                LanguageTagsEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                    .padding(.vertical, 6)
                    .settingsItem(.languages)
            }

            // Hidden while custom rules are gated off (CustomRulesCatalog.isUserFacingEnabled). The
            // editor and its storage are intentionally kept so re-enabling is a one-line flip.
            if CustomRulesCatalog.isUserFacingEnabled {
                Section("Rules") {
                    CustomRulesEditor(suggestionSettings: suggestionSettings, showsTitleHeader: false)
                        .padding(.vertical, 6)
                        .settingsItem(.customRules)
                }
            }
        }
    }

    private var autoAcceptTrailingPunctuationBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.autoAcceptTrailingPunctuation },
            set: { suggestionSettings.setAutoAcceptTrailingPunctuation($0) }
        )
    }

    private var addSpaceAfterAcceptBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.addSpaceAfterAccept },
            set: { suggestionSettings.setAddSpaceAfterAccept($0) }
        )
    }

    private var suppressCompletionsOnTypoBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.suppressCompletionsOnTypo },
            set: { suggestionSettings.setSuppressCompletionsOnTypo($0) }
        )
    }

    private var offerTypoCorrectionsBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.offerTypoCorrections },
            set: { suggestionSettings.setOfferTypoCorrections($0) }
        )
    }

    private var automaticallyFixTyposBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.automaticallyFixTypos },
            set: { suggestionSettings.setAutomaticallyFixTypos($0) }
        )
    }

    private var sentenceCheckBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isSentenceCheckEnabled },
            set: { suggestionSettings.setSentenceCheckEnabled($0) }
        )
    }

    private enum LengthChoice: Hashable {
        case preset(SuggestionWordCountPreset)
        case custom
    }

    private var lengthChoiceBinding: Binding<LengthChoice> {
        Binding(
            get: {
                suggestionSettings.isUsingCustomWordCountRange
                    ? .custom
                    : .preset(suggestionSettings.selectedWordCountPreset)
            },
            set: { choice in
                switch choice {
                case let .preset(preset):
                    suggestionSettings.setUsingCustomWordCountRange(false)
                    suggestionSettings.selectWordCountPreset(preset)
                case .custom:
                    suggestionSettings.setUsingCustomWordCountRange(true)
                }
            }
        )
    }

    /// A compact "type or step" control: a right-aligned numeric field paired with up/down arrows,
    /// both bound to the same clamping binding so a typed value and a stepped value land on the same
    /// sensible range. Factored out so the Min and Max rows stay identical. The field uses the
    /// `.number` format so it only commits a parsed integer on Return / focus loss, where the binding
    /// clamps it — intermediate keystrokes never fight the clamp. `label` is the spoken VoiceOver
    /// name: `LabeledContent`'s visible title is not applied to the controls themselves, so the field
    /// and stepper carry it explicitly (otherwise VoiceOver announces them unnamed).
    @ViewBuilder
    private func wordCountField(value: Binding<Int>, label: String) -> some View {
        HStack(spacing: 8) {
            TextField("", value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
            Stepper(
                "",
                value: value,
                in: SuggestionWordRange.minimumWord...SuggestionWordRange.maximumWord
            )
            .labelsHidden()
            .accessibilityLabel(label)
        }
    }

    private var customLowBinding: Binding<Int> {
        Binding(
            get: { suggestionSettings.customWordCountLowWords },
            set: { newLow in
                suggestionSettings.setCustomWordCountRange(
                    low: newLow,
                    high: suggestionSettings.customWordCountHighWords
                )
            }
        )
    }

    private var customHighBinding: Binding<Int> {
        Binding(
            get: { suggestionSettings.customWordCountHighWords },
            set: { newHigh in
                suggestionSettings.setCustomWordCountRange(
                    low: suggestionSettings.customWordCountLowWords,
                    high: newHigh
                )
            }
        )
    }
}
