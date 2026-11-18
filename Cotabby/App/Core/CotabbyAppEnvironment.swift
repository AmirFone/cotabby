import Combine
import Foundation
import Logging

/// File overview:
/// Builds Cotabby's long-lived dependency graph in one place. This is the app's composition model:
/// services are constructed once here, then handed to `AppDelegate` and the UI as shared owners.
///
/// In frontend terms, this plays the role of a top-level dependency container or provider tree.
/// The important architectural idea is that creation happens in one place, while usage happens
/// elsewhere. That keeps lifecycle ownership easy to follow.
@MainActor
final class CotabbyAppEnvironment {
    /// Where what is learned from the writer's sentences is kept, and the bundled lists that vouch
    /// for a word beyond the spelling dictionary.
    private struct WriterKnowledge {
        let vocabulary: PersonalVocabulary
        let phrases: PersonalPhraseModel
        let memory: PersonalCorrectionMemory
        let listedWords: Set<String>
        let recentWriting: RecentWriting
    }

    /// What the app learns from a sentence the writer finished and left unchanged. Their own words
    /// (names, jargon the dictionary lacks and the system checker accepts, or words they kept) go
    /// into their vocabulary; every word something vouches for is counted for the word strip, with
    /// the words before it (`PersonalPhraseModel.Vouching`).
    private static func learn(_ sentence: String, into knowledge: WriterKnowledge, coordinator: SuggestionCoordinator) {
        let vocabulary = knowledge.vocabulary, phrases = knowledge.phrases, memory = knowledge.memory
        let listedWords = knowledge.listedWords
        let corrector = coordinator.symSpellCorrector
        // Before the dictionary is read every word looks like one it lacks, and a sentence finished
        // in the first moment after launch taught `the` and `that` as the writer's own words.
        guard PersonalPhraseModel.isLearningEnabledInDefaults, corrector.isLoaded() else { return }
        let english = SpellingDictionaryLanguage.english.rawValue
        vocabulary.learn(
            sentence: sentence,
            isDictionaryWord: { corrector.isDictionaryWord($0) },
            isAcceptedSpelling: { memory.isKept($0) || !coordinator.spellChecker.isTypo($0, language: english) }
        )
        // A word the proofreader would still change (a slip it only suggests a fix for, or a
        // wrong-word mix-up like `went their`, which is all real words) is not counted; a sentence
        // it would rewrite on its own is not the writer's final text yet and is left out whole.
        guard let flagged = coordinator.wordsNotToLearn(in: sentence) else { return }
        // Shown to the word model before the next thing the writer types. Only a sentence with
        // nothing left to fix: a slip in it would otherwise be offered back from there.
        if flagged.isEmpty { knowledge.recentWriting.add(sentence) }
        phrases.learn(sentence: sentence, vouching: PersonalPhraseModel.Vouching(
            isWord: { word in
                !flagged.contains(word) && (corrector.isDictionaryWord(word) || listedWords.contains(word)
                    || vocabulary.preferredCasing(of: word) != nil || memory.isKept(word))
            },
            isOwnName: { word in
                !flagged.contains(word) && (vocabulary.preferredCasing(of: word) != nil || listedWords.contains(word))
            }
        ))
    }

    /// The sentence model stage of the sentence pass, or nil when its file is not installed (the
    /// pass then runs its local stage only). Loading the model (about 640 MB) starts here, in the
    /// background, so the first finished sentence does not wait for it. The service is kept alive by
    /// the closure, which the sentence controller holds for the life of the app.
    private static func sentenceModelProofread(
        suggestionCoordinator: SuggestionCoordinator
    ) -> (@MainActor (FinishedSentence) async -> LocalProofreadResult?)? {
        let sentenceModel = SentenceModelService(modelURL: SentenceModelService.defaultModelURL())
        guard sentenceModel.isInstalled else { return nil }
        sentenceModel.warmUp()
        return { [weak suggestionCoordinator] finished in
            guard let output = await sentenceModel.correct(finished.sentence) else { return nil }
            return suggestionCoordinator?.proofread(finished, modelOutput: output)
        }
    }

    /// Makes the toggle shortcut flip Cotabby and say so at the caret. Focus is not tracked while
    /// Cotabby is off: the snapshot kept from before the switch-off is still the right place for the
    /// "off" notice, but stale by the time it is switched back on, so the field is read again first.
    /// The notice controller is kept alive by the closure, which the input monitor holds.
    private static func answerToggleShortcut(
        inputMonitor: InputMonitor,
        settings: SuggestionSettingsModel,
        focusModel: FocusTrackingModel
    ) {
        let notice = ToggleNoticeController(
            panel: CandidateListPanelController(),
            caretRect: { [weak focusModel] in focusModel?.snapshot.context?.caretRect }
        )
        inputMonitor.onGlobalToggleHotkey = { [weak settings, weak focusModel] in
            guard let settings else { return }
            settings.toggleGloballyEnabled()
            let isOn = settings.isGloballyEnabled && !settings.isTemporarilyPaused
            if isOn { focusModel?.refreshNow() }
            notice.show(isOn: isOn, shortcutLabel: settings.globalToggleKeyLabel)
        }
    }

    private static func describe(_ model: TreeEnsembleModel?) -> String {
        model.map { "loaded (\($0.trees.count) trees, acts from \($0.threshold))" } ?? "missing or stale, using the hand rule"
    }

    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    /// Temporarily pauses Calendar AX traversal only while its date/time editor is active.
    let calendarAccessibilityCaptureGuard: CalendarAccessibilityCaptureGuard
    let appUpdateManager: AppUpdateManager
    let permissionGuidanceController: PermissionGuidanceController
    let suggestionSettings: SuggestionSettingsModel
    let openAICompatibleConnectionModel: OpenAICompatibleConnectionModel
    let endpointRateGovernor: EndpointRateGovernor
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let powerSourceMonitor: PowerSourceMonitor
    /// Process-lifetime Low Power Mode observer shared with suggestion orchestration.
    let lowPowerModeMonitor: LowPowerModeMonitor
    /// Detects when a composing input method (Japanese kana, Chinese pinyin, Korean hangul, ...) is
    /// active so `SuggestionInserter` commits accepted text through an IME-safe path instead of a
    /// synthetic keystroke the input method would swallow. See `KeyboardInputSourceMonitor`.
    let keyboardInputSourceMonitor: KeyboardInputSourceMonitor
    let clipboardContextProvider: ClipboardContextProvider
    let suggestionCoordinator: SuggestionCoordinator
    let emojiPickerController: EmojiPickerController
    let macroController: MacroController
    let inlineCommandCoordinator: InlineCommandCoordinator
    let emojiUsageStore: EmojiUsageStore
    let welcomeCoordinator: WelcomeCoordinator
    let huggingFaceSearchService: HuggingFaceSearchService
    let performanceMetricsStore: PerformanceMetricsStore
    let qualityMetricsStore: SuggestionQualityMetricsStore
    let settingsCoordinator: SettingsCoordinator
    let activationIndicatorController: ActivationIndicatorController
    let focusDebugOverlayController: FocusDebugOverlayController?

    private var cancellables = Set<AnyCancellable>()
    /// Warns once when the released Cotabby app is running alongside this build.
    private var otherCotabbyNotice: OtherCotabbyNoticeController?

    init() {
        CotabbyLogger.app.info("Building dependency graph")
        let configuration = SuggestionConfiguration.standard
        let permissionManager = PermissionManager()
        let permissionGuidanceController = PermissionGuidanceController(
            permissionManager: permissionManager
        )
        let runtimeManager = LlamaRuntimeManager()
        let runtimeModel = RuntimeBootstrapModel(runtimeManager: runtimeManager)
        let modelDownloadManager = ModelDownloadManager()
        let suggestionSettings = SuggestionSettingsModel(
            configuration: configuration,
            endpointCredentialStore: KeychainOpenAICompatibleCredentialStore(),
            groqCredentialStore: KeychainOpenAICompatibleCredentialStore(account: "groq-api-key")
        )
        let openAICompatibleClient = OpenAICompatibleAPIClient()
        let endpointRateGovernor = EndpointRateGovernor(
            tokensPerMinute: suggestionSettings.endpointTokensPerMinuteBudget
        )
        openAICompatibleClient.onRateLimitSnapshot = { [weak endpointRateGovernor] snapshot in
            endpointRateGovernor?.ingest(snapshot)
        }
        let openAICompatibleConnectionModel = OpenAICompatibleConnectionModel(
            client: openAICompatibleClient
        )
        let foundationModelAvailabilityService = FoundationModelAvailabilityService()
        let powerSourceMonitor = PowerSourceMonitor()
        let lowPowerModeMonitor = LowPowerModeMonitor()
        let keyboardInputSourceMonitor = KeyboardInputSourceMonitor()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        let calendarAccessibilityCaptureGuard = CalendarAccessibilityCaptureGuard()
        inputMonitor.onPointerDown = { [weak calendarAccessibilityCaptureGuard] point in
            calendarAccessibilityCaptureGuard?.handlePointerDown(atAccessibilityPoint: point)
        }
        inputMonitor.globalToggleKeyCodeProvider = { suggestionSettings.globalToggleKeyCode }
        inputMonitor.globalToggleKeyModifiersProvider = { suggestionSettings.globalToggleKeyModifiers }
        // Stop the deep AX walk when Cotabby is disabled for the focused app or while Calendar's
        // fragile date/time editor is active. The latter is interaction-scoped: Calendar text fields
        // still resolve normally, unlike the old app-wide suppression workaround for #544.
        let focusModel = FocusTrackingModel(
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier,
            // The Context pane's live-preview field is the single sanctioned spot where Cotabby may
            // complete inside its own UI; the focus tracker recognises it by this AX identifier.
            selfCaptureAllowedElementIdentifier: ContextLivePreview.accessibilityIdentifier,
            isCaptureSuppressedForBundle: { bundleIdentifier in
                guard suggestionSettings.isGloballyEnabled,
                      !suggestionSettings.isTemporarilyPaused
                else { return true }
                if let bundleIdentifier,
                   suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) {
                    return true
                }
                return calendarAccessibilityCaptureGuard.shouldSuppressCapture(
                    for: bundleIdentifier
                )
            },
            publishesPollingEvents: FocusDebugOverlayController.isEnabled
        )
        // The snapshot is poll-based, so after a fast app switch the closure may briefly
        // evaluate against the previous app's identity until the next AX poll fires. This
        // is the same race the downstream evaluator already has — not a new regression.
        inputMonitor.shouldProcessEventsProvider = { [weak focusModel] in
            guard suggestionSettings.isGloballyEnabled,
                  !suggestionSettings.isTemporarilyPaused
            else { return false }
            guard let snapshot = focusModel?.snapshot else { return true }
            if calendarAccessibilityCaptureGuard.shouldSuppressCapture(
                for: snapshot.bundleIdentifier
            ) {
                return false
            }
            if TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier) { return false }
            if let bundleID = snapshot.bundleIdentifier,
               suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleID) {
                return false
            }
            return true
        }
        // Resolve against the latest focus snapshot so each keystroke uses that app's binding.
        // The snapshot can briefly lag a fast switch, matching the evaluator race above.
        inputMonitor.acceptanceBindingProvider = { [weak focusModel] in
            let binding = suggestionSettings.resolvedAcceptBinding(
                forBundleIdentifier: focusModel?.snapshot.bundleIdentifier
            )
            return (binding.keyCode, binding.modifiers)
        }
        inputMonitor.fullAcceptanceBindingProvider = { [weak focusModel] in
            let binding = suggestionSettings.resolvedFullAcceptBinding(
                forBundleIdentifier: focusModel?.snapshot.bundleIdentifier
            )
            return (binding.keyCode, binding.modifiers)
        }
        let appUpdateManager = AppUpdateManager()
        let welcomeCoordinator = WelcomeCoordinator(
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService
        )
        let huggingFaceSearchService = HuggingFaceSearchService()
        let performanceMetricsStore = PerformanceMetricsStore()
        // Always-on quality counters (generated / shown / suppressed-by-reason / accepted).
        // Counters only, no content, so unlike latency tracking there is no opt-in gate.
        let qualityMetricsStore = SuggestionQualityMetricsStore()
        // Live CPU/RAM graph backing for the Performance pane. Holds no state until the pane asks it
        // to start sampling, so constructing it eagerly here costs nothing.
        let systemMetricsStore = SystemMetricsStore()
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        // While a fix deletes and retypes text, the writer's own keys wait and are replayed after it.
        suggestionInserter.onWillPostDeletingEdit = { [weak inputMonitor] in
            inputMonitor?.holdTypingWhileEditsDrain()
        }
        // Commit accepted text through an IME-safe path (Accessibility / paste) while a composing IME
        // is active; a synthetic keystroke would be re-absorbed into composition and the accept would
        // silently fail.
        suggestionInserter.isComposingIMEActiveProvider = { [weak keyboardInputSourceMonitor] in
            keyboardInputSourceMonitor?.isComposingIMEActive ?? false
        }
        let overlayController = OverlayController(suggestionSettings: suggestionSettings)
        let activationIndicatorController = ActivationIndicatorController()
        let clipboardContextProvider = ClipboardContextProvider()
        let clipboardRelevanceFilter = ClipboardRelevanceFilter()
        let screenshotContextGenerator = ScreenshotContextGenerator()
        let visualContextCoordinator = VisualContextCoordinator(
            screenshotContextGenerator: screenshotContextGenerator,
            screenRecordingPermissionProvider: { permissionManager.screenRecordingGranted }
        )
        let foundationModelEngine: any SuggestionGenerating
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            foundationModelEngine = FoundationModelSuggestionEngine(
                availabilityService: foundationModelAvailabilityService
            )
            CotabbyLogger.app.info("Foundation model engine available")
        } else {
            foundationModelEngine = UnavailableSuggestionEngine(
                message: foundationModelAvailabilityService.userVisibleMessage
            )
            CotabbyLogger.app.info("Foundation model engine unavailable (macOS version)")
        }
        #else
        foundationModelEngine = UnavailableSuggestionEngine(
            message: foundationModelAvailabilityService.userVisibleMessage
        )
        CotabbyLogger.app.info("Foundation model engine unavailable (SDK)")
        #endif

        let suggestionEngine: any SuggestionGenerating = SuggestionEngineRouter(
            suggestionSettings: suggestionSettings,
            foundationModelEngine: foundationModelEngine,
            llamaEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager),
            performanceMetricsStore: performanceMetricsStore,
            qualityMetricsStore: qualityMetricsStore,
            llamaModelNameProvider: { [weak runtimeManager] in
                runtimeManager?.currentModelFilename
            },
            openAICompatibleEngine: OpenAICompatibleSuggestionEngine(
                client: openAICompatibleClient,
                configurationProvider: { [weak suggestionSettings] in
                    guard let suggestionSettings else {
                        throw OpenAICompatibleClientError.invalidResponse
                    }
                    return try suggestionSettings.openAICompatibleConfiguration
                },
                apiKeyProvider: { [weak suggestionSettings] in
                    try suggestionSettings?.openAICompatibleAPIKey()
                },
                rateGovernor: endpointRateGovernor
            ),
            endpointModelNameProvider: { [weak suggestionSettings] in
                suggestionSettings?.activeEndpointModelName.nonEmpty
            }
        )

        // Per-user emoji recents/frequency. Built before the settings coordinator so the
        // "Clear History" control can reach it, and before the picker which reads and writes it.
        let emojiUsageStore = EmojiUsageStore()

        let jevKeyModel = JevKeyModel()
        let personalPhraseModel = PersonalPhraseModel()
        let personalVocabulary = PersonalVocabulary(fileURL: PersonalVocabulary.defaultFileURL())
        let recentWriting = RecentWriting()
        let correctionJournal = CorrectionJournal()
        // The opt-in training record hears of every word event through the journal, so the call
        // sites that already report to the journal need no second line.
        let trainingLog = TrainingLog()
        correctionJournal.onRecord = { kind, typed, final, offered in
            trainingLog.noteWord(kind, typed: typed, final: final, offered: offered)
        }
        let settingsCoordinator = SettingsCoordinator(
            appUpdateManager: appUpdateManager,
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            suggestionSettings: suggestionSettings,
            openAICompatibleConnectionModel: openAICompatibleConnectionModel,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            huggingFaceSearchService: huggingFaceSearchService,
            performanceMetricsStore: performanceMetricsStore,
            qualityMetricsStore: qualityMetricsStore,
            systemMetricsStore: systemMetricsStore,
            jevKeyModel: jevKeyModel,
            onShowWelcome: { [weak welcomeCoordinator] in
                welcomeCoordinator?.showWelcome()
            },
            clearEmojiHistory: { emojiUsageStore.clear() },
            clearLearnedPhrases: {
                personalPhraseModel.reset()
                personalVocabulary.reset()
                recentWriting.clear()
            },
            correctionJournal: correctionJournal,
            trainingLog: trainingLog
        )

        let interactionState = SuggestionInteractionState()
        let workController = SuggestionWorkController()
        // Constructed once at app scope so the underlying `NSSpellChecker` document tag survives
        // across coordinator state transitions instead of churning per keystroke.
        let spellChecker = CurrentWordSpellChecker()
        // No launch-time preload: a fully built index costs tens of MB resident for a feature that
        // is only consulted once the typo gate actually finds a misspelling, and the first
        // consultation triggers the same background build (`cachedIndexOrRequestLoad`) with the
        // designed NSSpellChecker fallback ranking corrections until it lands. The only cost of
        // staying cold is that the first correction or two after launch rank via the system
        // checker instead of corpus frequency.
        // Preloaded in the background at launch: the first typo of a session should get the full
        // dictionary ranking (and its automatic fix) rather than the weaker system-guess fallback.
        let symSpellCorrector = SymSpellCorrector(
            preloadLanguage: suggestionSettings.snapshot.enabledSpellingDictionaryCodes.isEmpty ? nil : .english
        )
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            lowPowerModeProvider: lowPowerModeMonitor,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: suggestionInserter,
            suggestionEngine: suggestionEngine,
            suggestionSettings: suggestionSettings,
            clipboardContextProvider: clipboardContextProvider,
            clipboardRelevanceFilter: clipboardRelevanceFilter,
            visualContextCoordinator: visualContextCoordinator,
            interactionState: interactionState,
            workController: workController,
            configuration: configuration,
            spellChecker: spellChecker,
            symSpellCorrector: symSpellCorrector,
            spellingLanguageResolver: SpellingLanguageResolver(),
            qualityMetricsStore: qualityMetricsStore
        )

        // The emoji picker is a sibling to the suggestion coordinator. It reuses the input monitor,
        // focus model, and inserter, but owns its own trigger state machine and floating panel.
        let emojiPickerController = EmojiPickerController(
            // Deferred: decoding and indexing the bundled emoji catalog costs a few MB of resident
            // strings that most sessions never use; the picker builds it on first `:` capture.
            matcherProvider: { EmojiMatcher(catalog: EmojiCatalog.bundled()) },
            panel: EmojiPickerPanelController(),
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            inserter: suggestionInserter,
            isEnabled: { suggestionSettings.isEmojiPickerEnabled },
            emojiPreferences: { suggestionSettings.emojiVariantPreferences },
            emojiUsage: { emojiUsageStore.snapshot() },
            recordEmojiUsage: { emojiUsageStore.record(alias: $0) }
        )
        // The macro preview is a second inline-command provider, on the `/` sigil. It reuses the same
        // input monitor, focus model, and inserter as the emoji picker, and renders a single-row
        // preview near the caret.
        let macroController = MacroController(
            engine: MacroEngine.standard(),
            panel: InlinePreviewPanelController(),
            focusModel: focusModel,
            inserter: suggestionInserter,
            isEnabled: { suggestionSettings.isMacroExpansionEnabled },
            acceptKeyLabel: {
                suggestionSettings.emojiPickerAcceptKeyLabel(
                    forBundleIdentifier: focusModel.snapshot.bundleIdentifier
                )
            },
            isWordAcceptKey: { inputMonitor.isWordAcceptKey($0) }
        )
        // One coordinator fans every keystroke out to both inline-command controllers and owns the
        // input monitor's single capture decider and interception flag, which the `:` and `/` features
        // share. It is given first look at every keystroke the suggestion coordinator receives.
        // The candidate list rides the same single capture slot as the emoji picker and macros. It is
        // fed by the suggestion coordinator (typo gate, alternates) rather than by its own trigger.
        let personalCorrectionMemory = PersonalCorrectionMemory()
        let candidateListController = CandidateListController(
            panel: CandidateListPanelController(),
            focusModel: focusModel,
            inserter: suggestionInserter,
            isWordAcceptKey: { inputMonitor.isWordAcceptKey($0) },
            acceptKeyLabel: {
                suggestionSettings.emojiPickerAcceptKeyLabel(
                    forBundleIdentifier: focusModel.snapshot.bundleIdentifier
                ) ?? "Return"
            },
            correctionMemory: personalCorrectionMemory,
            qualityMetricsStore: qualityMetricsStore
        )
        candidateListController.onCommitted = { [weak suggestionCoordinator] in
            suggestionCoordinator?.schedulePredictionAfterHostPublishDelay()
        }
        candidateListController.journal = correctionJournal
        candidateListController.onDismissedByEscape = { [weak suggestionCoordinator] in
            suggestionCoordinator?.noteSpellingBarDismissed()
        }
        suggestionCoordinator.correctionJournal = correctionJournal
        suggestionCoordinator.candidateOfferPresenter = candidateListController
        suggestionCoordinator.personalCorrectionMemory = personalCorrectionMemory
        suggestionCoordinator.bigramContextModel = BigramContextModel()
        let wordIntentRefiner = WordIntentRefiner(apiKeyProvider: { jevKeyModel.readAPIKey() })
        wordIntentRefiner.onRefined = { [weak suggestionCoordinator] in
            suggestionCoordinator?.schedulePrediction()
        }
        jevKeyModel.onKeyChanged = { [weak wordIntentRefiner] in
            wordIntentRefiner?.reloadAPIKey()
        }
        suggestionCoordinator.wordIntentRefiner = wordIntentRefiner

        let modelProofread = Self.sentenceModelProofread(suggestionCoordinator: suggestionCoordinator)
        let sentenceCheckController = SentenceCheckController(
            panel: CandidateListPanelController(),
            focusModel: focusModel,
            inserter: suggestionInserter,
            client: openAICompatibleClient,
            configurationProvider: { try suggestionSettings.openAICompatibleConfiguration },
            apiKeyProvider: { try suggestionSettings.openAICompatibleAPIKey() },
            rateGovernor: endpointRateGovernor,
            isEnabled: {
                let snapshot = suggestionSettings.snapshot
                return snapshot.isSentenceCheckEnabled && snapshot.usesCloudEndpoint && snapshot.isGloballyEnabled
            },
            knownTerms: {
                let notes = suggestionSettings.extendedContext.trimmingCharacters(in: .whitespacesAndNewlines)
                return notes.isEmpty ? nil : notes
            },
            acceptKeyLabel: {
                suggestionSettings.emojiPickerAcceptKeyLabel(
                    forBundleIdentifier: focusModel.snapshot.bundleIdentifier
                ) ?? "Tab"
            },
            isWordAcceptKey: { inputMonitor.isWordAcceptKey($0) },
            qualityMetricsStore: qualityMetricsStore,
            localProofread: { [weak suggestionCoordinator] finished in
                suggestionCoordinator?.proofreadLocally(finished)
            },
            modelProofread: modelProofread,
            isLocalEnabled: {
                let snapshot = suggestionSettings.snapshot
                return snapshot.isGloballyEnabled && (snapshot.offerTypoCorrections || snapshot.automaticallyFixTypos)
            },
            appliesLocalFixes: { suggestionSettings.snapshot.automaticallyFixTypos }
        )
        sentenceCheckController.onWillShowFix = { [weak suggestionCoordinator] in
            suggestionCoordinator?.standDownForInlinePanel()
        }
        sentenceCheckController.onCommitted = { [weak suggestionCoordinator] in
            suggestionCoordinator?.schedulePredictionAfterHostPublishDelay()
        }
        sentenceCheckController.onLocalFixOutcome = { original, corrected, kept in
            trainingLog.noteSentenceFix(original: original, corrected: corrected, kept: kept)
            let changes = SentenceFixOutcomeTracker.wordChanges(original: original, corrected: corrected)
            personalCorrectionMemory.record(changes: changes, kept: kept)
            changes.forEach { correctionJournal.record(kept ? .sentenceFixKept : .sentenceFixUndone, typed: $0.typed, final: $0.fixed) }
        }
        // A word kept on the review card is not flagged again: a real word under the same
        // "previous word + word" key the wrong-word checks read, a misspelling under the word itself.
        sentenceCheckController.onReviewChoice = { typed, previous, chosen in
            let kind = personalCorrectionMemory.recordReviewChoice(
                typed: typed,
                previous: previous,
                chosen: chosen,
                isRealWord: symSpellCorrector.isDictionaryWord(typed)
            )
            correctionJournal.record(kind == .accepted ? .picked : .keptAsTyped, typed: typed, final: chosen)
        }
        suggestionCoordinator.sentenceFixPresenter = sentenceCheckController

        // One memory-mapped n-gram table serves the word strip and sentence-aware spelling.
        let nextWordModel = NextWordModel.bundled(prewarm: true)
        // Words the bundled lists vouch for beyond the spelling dictionary (everyday words it
        // lacks, software terms), so a sentence with one of them still teaches the strip.
        let knowledge = WriterKnowledge(
            vocabulary: personalVocabulary, phrases: personalPhraseModel, memory: personalCorrectionMemory,
            listedWords: WordPredictionController.supplementWords(), recentWriting: recentWriting
        )
        suggestionCoordinator.nextWordModel = nextWordModel
        suggestionCoordinator.autoFixModel = AutoFixFeatures.bundledModel()
        let americanSpellings = AmericanSpellings.preferredOnThisMac()
        suggestionCoordinator.americanSpellings = americanSpellings
        suggestionCoordinator.wrongWordModel = WrongWordDetector.bundledModel()
        // A model file trained on another feature list is rejected, and the hand rules take over
        // silently; this line is how a stale file shows up in the logs.
        let autoFixState = Self.describe(suggestionCoordinator.autoFixModel)
        let wrongWordState = Self.describe(suggestionCoordinator.wrongWordModel)
        CotabbyLogger.app.info("Spelling models: auto-fix \(autoFixState), wrong-word \(wrongWordState)")
        // The language model that orders the word strip by the whole text so far (tense, topic),
        // loaded in the background so the first word does not wait for it.
        let wordLanguageModel = WordLanguageModelService(
            modelURL: WordLanguageModelService.defaultModelURL(),
            wordListURLs: WordLanguageModelService.bundledWordListURLs(),
            recentWriting: recentWriting
        )
        wordLanguageModel.warmUp()
        let wordPredictionController = WordPredictionController(
            panel: CandidateListPanelController(),
            focusModel: focusModel,
            inserter: suggestionInserter,
            predict: WordPredictionController.makePredictor(
                model: nextWordModel,
                symSpellCorrector: symSpellCorrector,
                phrases: personalPhraseModel,
                vocabulary: personalVocabulary,
                languageModel: wordLanguageModel,
                americanSpellings: americanSpellings
            ),
            isEnabled: {
                suggestionSettings.snapshot.isGloballyEnabled && WordPredictionController.isEnabledInDefaults
            },
            learn: { sentence in
                Self.learn(sentence, into: knowledge, coordinator: suggestionCoordinator)
            },
            isSpellingPending: { [weak suggestionCoordinator] in
                suggestionCoordinator?.isSpellingPendingForLastKey ?? false
            },
            isLanguageModelPending: { wordLanguageModel.isAnswerPending(forTextBefore: $0) }
        )
        wordPredictionController.onSentenceSettled = { [weak focusModel] sentence in
            let snapshot = focusModel?.snapshot
            trainingLog.noteSentence(sentence, textBefore: snapshot?.context?.precedingText, app: snapshot?.bundleIdentifier)
        }
        wordPredictionController.onStripUse = { trainingLog.noteStrip($0) }
        suggestionCoordinator.onSpellingDecision = { trainingLog.noteDecision($0) }
        suggestionCoordinator.onSentencePass = { trainingLog.noteSentencePass($0, words: $1) }
        trainingLog.session = {
            .session(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                stripModel: WordLanguageModelService.defaultModelURL()?.lastPathComponent,
                hasSentenceModel: FileManager.default.fileExists(atPath: SentenceModelService.defaultModelURL().path)
            )
        }
        wordLanguageModel.onReady = { [weak wordPredictionController] in
            wordPredictionController?.redrawWithLanguageModel()
        }
        wordPredictionController.onCommitted = { [weak suggestionCoordinator] in
            qualityMetricsStore.recordWordPredictionPicked()
            suggestionCoordinator?.schedulePredictionAfterHostPublishDelay()
        }
        suggestionCoordinator.wordPredictionPresenter = wordPredictionController
        candidateListController.onPickAddedSpace = { [weak wordPredictionController] expected in
            wordPredictionController?.notePickAddedSpace(expectedText: expected)
        }
        suggestionCoordinator.personalPhraseModel = personalPhraseModel
        suggestionCoordinator.personalVocabulary = personalVocabulary
        suggestionCoordinator.technicalTerms = TechnicalVocabulary.spellingTerms()

        Self.answerToggleShortcut(inputMonitor: inputMonitor, settings: suggestionSettings, focusModel: focusModel)
        let otherCotabbyNotice = OtherCotabbyNoticeController(panel: CandidateListPanelController())
        otherCotabbyNotice.start(focus: focusModel.snapshotPublisher)
        self.otherCotabbyNotice = otherCotabbyNotice
        // Off means nothing of Cotabby's stays on screen, however it was switched off (shortcut,
        // menu, Settings, or a timed pause). The panels belong to three controllers that otherwise
        // only hide on a keystroke, and keystrokes stop reaching them the moment Cotabby is off.
        // `@Published` hands the sink the new values before the properties change, so the closure
        // reads its arguments, not the model.
        Publishers.CombineLatest(suggestionSettings.$isGloballyEnabled, suggestionSettings.$pauseState)
            .map { isEnabled, pause in isEnabled && pause?.isActive() != true }
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak candidateListController, weak sentenceCheckController, weak wordPredictionController] _ in
                candidateListController?.dismissChoices()
                sentenceCheckController?.standDown()
                wordPredictionController?.hidePredictions()
            }
            .store(in: &cancellables)

        let inlineCommandCoordinator = InlineCommandCoordinator(
            emoji: emojiPickerController,
            macro: macroController,
            participants: [candidateListController, sentenceCheckController, wordPredictionController],
            inputMonitor: inputMonitor
        )
        suggestionCoordinator.emojiInputObserver = { [weak inlineCommandCoordinator] event in
            inlineCommandCoordinator?.observe(event) ?? false
        }

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.calendarAccessibilityCaptureGuard = calendarAccessibilityCaptureGuard
        self.appUpdateManager = appUpdateManager
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.openAICompatibleConnectionModel = openAICompatibleConnectionModel
        self.endpointRateGovernor = endpointRateGovernor
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.powerSourceMonitor = powerSourceMonitor
        self.lowPowerModeMonitor = lowPowerModeMonitor
        self.keyboardInputSourceMonitor = keyboardInputSourceMonitor
        self.clipboardContextProvider = clipboardContextProvider
        self.suggestionCoordinator = suggestionCoordinator
        self.emojiPickerController = emojiPickerController
        self.macroController = macroController
        self.inlineCommandCoordinator = inlineCommandCoordinator
        self.emojiUsageStore = emojiUsageStore
        self.welcomeCoordinator = welcomeCoordinator
        self.huggingFaceSearchService = huggingFaceSearchService
        self.performanceMetricsStore = performanceMetricsStore
        self.qualityMetricsStore = qualityMetricsStore
        self.settingsCoordinator = settingsCoordinator
        self.activationIndicatorController = activationIndicatorController
        self.focusDebugOverlayController = FocusDebugOverlayController.isEnabled
            ? FocusDebugOverlayController()
            : nil

        // Update the AX polling timer whenever the user changes the poll interval setting.
        suggestionSettings.$focusPollIntervalMilliseconds
            .removeDuplicates()
            .sink { [weak focusModel] milliseconds in
                focusModel?.updatePollInterval(milliseconds: milliseconds)
            }
            .store(in: &cancellables)

        // Key code changes reach InputMonitor through closures that read from the model
        // at event time (set above), so no Combine subscription is needed here.

        // The global-toggle hotkey is the exception: its tap is install-on-demand so a user who
        // never binds it pays zero per-keystroke cost. Install/uninstall whenever the binding
        // crosses the unbound/bound boundary or when the key code itself changes.
        suggestionSettings.$globalToggleKeyCode
            .removeDuplicates()
            .sink { [weak inputMonitor] _ in
                inputMonitor?.refreshToggleTap()
            }
            .store(in: &cancellables)

        observePowerSourceProfileSwitching()
        observeOpenAICompatibleSelection()
    }

    /// Applies the user's per-power-source profile (engine + model) whenever anything that could
    /// change the right answer changes: the power source, the feature toggle, either profile, or the
    /// installed-model list (so a profile referencing a still-loading model is honored once it
    /// appears). The apply step is idempotent (`selectEngine`/`selectModel` no-op when already
    /// current), so the redundant values `@Published` replays on subscription are harmless.
    /// Extracted from `init` to keep the initializer's complexity bounded.
    private func observePowerSourceProfileSwitching() {
        let triggers: [AnyPublisher<Void, Never>] = [
            powerSourceMonitor.$isPluggedIn.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$isPowerBasedModelSwitchingEnabled.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$batteryEngine.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$batteryModelFilename.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$batteryEndpointModelName.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInEngine.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInModelFilename.map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$pluggedInEndpointModelName.map { _ in () }.eraseToAnyPublisher(),
            runtimeModel.$availableModels.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(triggers)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }

                Self.applyPowerProfile(
                    isPluggedIn: self.powerSourceMonitor.isPluggedIn,
                    runtimeModel: self.runtimeModel,
                    suggestionSettings: self.suggestionSettings,
                    availability: self.foundationModelAvailabilityService
                )
            }
            .store(in: &cancellables)
    }

    /// Switches the active engine (and, for Open Source, the model) to the profile configured for the
    /// current power source. Does nothing when the feature is off. Apple Intelligence is applied only
    /// when actually available, so a configured-but-unavailable profile never strands the user on a
    /// dead engine; the Open Source branch reloads the model only when it is installed and not already
    /// selected, so the sole side effect is a deliberate reload on a real change.
    private static func applyPowerProfile(
        isPluggedIn: Bool,
        runtimeModel: RuntimeBootstrapModel,
        suggestionSettings: SuggestionSettingsModel,
        availability: FoundationModelAvailabilityService
    ) {
        guard suggestionSettings.isPowerBasedModelSwitchingEnabled else {
            return
        }

        let profile = isPluggedIn ? suggestionSettings.pluggedInProfile : suggestionSettings.batteryProfile

        switch profile {
        case .appleIntelligence:
            guard availability.isAvailable else {
                return
            }

            suggestionSettings.selectEngine(.appleIntelligence)

        case .llama(let filename):
            suggestionSettings.selectEngine(.llamaOpenSource)

            guard !filename.isEmpty,
                  runtimeModel.availableModels.contains(where: { $0.filename == filename }),
                  runtimeModel.selectedModelFilename != filename else {
                return
            }

            Task {
                await runtimeModel.selectModel(filename)
            }
        case .openAICompatible(let modelName):
            guard !modelName.isEmpty else { return }
            suggestionSettings.setActiveEndpointModelName(modelName)
            suggestionSettings.selectEngine(.openAICompatible)
        }
    }

    /// Connect once when the endpoint engine becomes active. Only server identity and credentials
    /// invalidate discovery: the selected model and generation route do not affect `GET /models`,
    /// so changing either must keep the catalog and connected status alive. Settings still owns
    /// explicit Connect/Return refreshes and avoids network traffic per keystroke.
    private func observeOpenAICompatibleSelection() {
        suggestionSettings.$endpointTokensPerMinuteBudget
            .removeDuplicates()
            .sink { [weak self] budget in
                self?.endpointRateGovernor.setTokensPerMinute(budget)
            }
            .store(in: &cancellables)

        // `@Published` emits before the property changes, so the sink must use the emitted values
        // rather than reading `selectedEngine` back off the settings model.
        Publishers.CombineLatest(
            suggestionSettings.$selectedEngine.removeDuplicates(),
            suggestionSettings.$endpointProvider.removeDuplicates()
        )
            .sink { [weak self] engine, _ in
                guard engine == .openAICompatible, let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let configuration = try self.suggestionSettings.openAICompatibleConfiguration
                        let apiKey = try self.suggestionSettings.openAICompatibleAPIKey()
                        await self.openAICompatibleConnectionModel.refresh(
                            configuration: configuration,
                            apiKey: apiKey
                        )
                    } catch {
                        self.openAICompatibleConnectionModel.invalidate()
                    }
                }
            }
            .store(in: &cancellables)

        let configurationChanges: [AnyPublisher<Void, Never>] = [
            suggestionSettings.$openAICompatibleBaseURL.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            suggestionSettings.$endpointCredentialRevision.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(configurationChanges)
            .sink { [weak self] _ in
                guard let self, self.suggestionSettings.selectedEngine == .openAICompatible else { return }
                self.openAICompatibleConnectionModel.invalidate()
            }
            .store(in: &cancellables)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
