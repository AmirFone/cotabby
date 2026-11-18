import Combine
import Foundation

/// File overview:
/// Declares the shared state and dependency graph for Cotabby's inline-completion orchestrator.
/// The behavior now lives in `SuggestionCoordinator+*.swift` files so maintainers can read the
/// state machine by concern instead of scrolling through one monolithic source file.
///
/// Swift does not offer a "type-private across multiple files" access level. Because this
/// coordinator is split across extension files, coordinator-owned mutable state uses module
/// visibility and is protected by convention: other types should observe these properties, not
/// mutate them.
@MainActor
final class SuggestionCoordinator: ObservableObject {
    /// Coordinator-owned state machine values. Tests inspect these directly, but no UI subscribes
    /// to them, so keeping them as plain properties avoids unrelated menu re-renders.
    var state: SuggestionDebugState = .idle
    var overlayState: OverlayState = .hidden(reason: "Overlay idle.")
    var latestGenerationNumber: UInt64?
    @Published var visualContextStatus: VisualContextStatus = .idle
    @Published var latestVisualContextText: String?
    @Published var totalTabAcceptedWordCount: Int = 0

    // Core collaborators. The coordinator depends on capability-shaped protocols here so its
    // orchestration logic stays separated from concrete service implementations.
    let permissionManager: any SuggestionPermissionProviding
    /// Provides the initial Low Power Mode state and subsequent transitions.
    let lowPowerModeProvider: any SuggestionLowPowerModeProviding
    let focusModel: any SuggestionFocusProviding
    let inputMonitor: any SuggestionInputMonitoring
    let overlayController: any SuggestionOverlayControlling
    let suggestionInserter: any SuggestionInserting
    let suggestionEngine: any SuggestionGenerating
    let suggestionSettings: any SuggestionSettingsProviding
    let clipboardContextProvider: any ClipboardContextProviding
    let clipboardRelevanceFilter: any ClipboardRelevanceFiltering
    let visualContextCoordinator: any VisualContextCoordinating
    let interactionState: SuggestionInteractionState
    let workController: SuggestionWorkController
    let configuration: SuggestionConfiguration
    let userDefaults: UserDefaults
    let overlayPresenter: SuggestionOverlayPresenter
    let logger: SuggestionDebugLogger
    /// Drives the typo gate before each prediction. Owned at app scope (constructed once in
    /// `CotabbyAppEnvironment`) so the underlying `NSSpellChecker` document tag persists across the
    /// coordinator's lifetime instead of churning per keystroke.
    let spellChecker: CurrentWordSpellChecker
    /// Always-on quality counters (shown / suppressed / accepted). The router counts generation
    /// outcomes; the coordinator owns the display-time and acceptance events only it can see.
    let qualityMetricsStore: SuggestionQualityMetricsStore
    /// Frequency-ranked correction source (SymSpell). Used first for the correction word, with
    /// `spellChecker` as the fallback while its index is still loading or when it has no suggestion.
    let symSpellCorrector: SymSpellCorrector
    /// Chooses at most one enabled SymSpell language from the text surrounding the typo. Ambiguous
    /// contexts return nil so correction ranking falls back to the system spell checker.
    let spellingLanguageResolver: SpellingLanguageResolver

    /// Optional first-look hook the emoji picker installs to observe the keystroke stream. Called at
    /// the very top of `handleInputEvent`, before any suggestion logic. Returns `true` when an emoji
    /// capture is involved with this key, in which case the coordinator stands down so ghost text does
    /// not compete with the picker. It never consumes keys here (the listen-only observer cannot);
    /// consumption happens through `InputMonitor.emojiCaptureKeyDecider`.
    var emojiInputObserver: ((CapturedInputEvent) -> Bool)?

    /// The pick-list for ambiguous misspellings and ghost-text alternates. Set by the composition root
    /// after the inline-command controllers exist; nil in tests that do not exercise the list.
    var candidateOfferPresenter: (any CandidateOfferPresenting)?
    /// The writer's history of accepted fixes, which boosts those fixes the next time the same typo
    /// appears. Nil disables the boost.
    var personalCorrectionMemory: PersonalCorrectionMemory?
    /// Local word-pair counts that let corrections use the previous word. Nil disables context.
    var bigramContextModel: BigramContextModel?
    /// Optional Jev decisions for spelling choices the local evidence cannot settle.
    var wordIntentRefiner: WordIntentRefiner?
    /// The bundled n-gram table, used as sentence context when ranking spelling fixes. Nil in tests.
    var nextWordModel: NextWordModel?
    /// Spelling work done ahead of the host publishing a word-ending key (see `prepareTypoGate`).
    struct PreparedTypoGate {
        let precedingText: String
        let textAfter: String
        let inputs: TypoGateInputs
    }

    var preparedTypoGate: PreparedTypoGate?
    /// The work prepared for the last typed key ends in a fix, the bar, or a suppression. Read by
    /// the word strip, which then leaves that key alone.
    var isSpellingPendingForLastKey = false
    /// When the last typed key reached `handleInputEvent`, so the timings count from the key itself
    /// and include the spelling work done there. Consumed by the publish wait.
    var pendingKeystrokeUptimeNanoseconds: UInt64?
    /// The text before the caret the last time the spelling gate looked at the field. A key whose
    /// character is already at the end of the field *beyond* this text was published by the host
    /// before Cotabby's key callback ran (see `prepareSpellingAtKeystroke`).
    var lastGatedPrecedingText: String?
    /// The field already showed the last typed key when its callback ran. Consumed by the publish wait.
    var fieldAlreadyShowsLastKey = false
    /// The word the writer closed the spelling bar on with Escape; left alone until the caret moves on.
    var dismissedTypo: DismissedTypo?
    /// When the last typing key was seen, for the "fixed N ms after the key" debug log.
    var lastTypingKeystrokeUptimeNanoseconds: UInt64 = 0
    /// The trained judge of which spelling fix to put first and whether to apply it unasked; set by
    /// the app environment, nil in tests and when the bundled file does not match this build.
    var autoFixModel: TreeEnsembleModel?
    /// The American spelling of words written two ways, when this Mac's region uses it.
    var americanSpellings: AmericanSpellings?
    /// What the spelling engine decided about a word, with its candidates and confidence, at the
    /// moment it decided. The opt-in training record listens here.
    var onSpellingDecision: ((SpellingDecisionRecord) -> Void)?
    /// The words the sentence model would change in a finished sentence, each with its probability
    /// and what the gate did about it. The opt-in training record listens here.
    var onSentencePass: ((_ sentence: String, _ words: [SentencePassWord]) -> Void)?
    /// The trained judge of correctly spelled wrong words for the sentence pass.
    var wrongWordModel: TreeEnsembleModel?
    /// The writer's learned phrases, also used as spelling context. Nil in tests.
    var personalPhraseModel: PersonalPhraseModel?
    /// The writer's own words (names, jargon) as correction targets; set by the app environment.
    var personalVocabulary: PersonalVocabulary?
    /// The bundled software terms the spelling dictionary took (lowercase); the sentence model
    /// leaves them as typed. Empty when that vocabulary is off.
    var technicalTerms: Set<String> = []
    /// Auto-fixes waiting for the writer's reaction; only kept fixes teach the personal history.
    var autoFixOutcomes = AutoFixOutcomeTracker()
    /// Watches for the writer retyping a misspelled word themselves.
    var selfCorrections = SelfCorrectionDetector()
    /// Local record of spelling outcomes (see `CorrectionJournal`). Nil in tests.
    var correctionJournal: CorrectionJournal?
    /// The next-word strip. Nil in tests and when word predictions are unavailable.
    var wordPredictionPresenter: (any WordPredictionPresenting)?
    /// Proofreads finished sentences on cloud endpoints. Nil in tests and when unavailable.
    var sentenceFixPresenter: (any SentenceFixPresenting)?

    /// True while a Cotabby panel owns Tab, so late-arriving ghost text must not appear under it.
    var isInlinePanelOwningKeys: Bool {
        candidateOfferPresenter?.isShowingChoices == true || sentenceFixPresenter?.isShowingFix == true
    }

    static let totalTabAcceptedWordCountDefaultsKey = "cotabbyTotalAcceptedWordCount"
    /// Long enough for the host to publish the typed space to Accessibility.
    static let typeThroughSentenceCheckDelaySeconds: TimeInterval = 0.12
    /// Field changes this soon after Cotabby's own keys are the app's edits, not the writer's.
    static let ownEditQuietSeconds: TimeInterval = 1.0

    // Combine subscriptions are the coordinator's remaining direct mutable bookkeeping.
    // Async work and active-session storage now live in dedicated collaborators below.
    var cancellables = Set<AnyCancellable>()
    var settingsSnapshot: SuggestionSettingsSnapshot
    /// Last completed round trip per backend, retained across keystrokes. Keeping this separate lets
    /// a slow HTTP backend retain an appropriate debounce without leaking that latency into the
    /// in-process engines.
    var lastLatencyByEngine: [SuggestionEngineKind: Int] = [:]
    // Synchronous input/focus callbacks cannot directly `await`, so resets are represented as a
    // barrier task that the next generation must cross before it can ask the runtime for output.
    var cacheResetSequence: UInt64 = 0
    var pendingCacheReset: (sequence: UInt64, task: Task<Void, Never>)?
    /// One accepted clipboard-relevance verdict per (field session, pasteboard state). The verdict
    /// used to be re-evaluated against the live prefix on every request, and because the clipboard
    /// section precedes the typed prefix in the prompt, every flip rewrote the prompt HEAD and
    /// collapsed the engine's reusable common prefix back to zero (a full re-prefill). A pinned
    /// non-nil verdict keeps the prompt head stable for the field session; a nil verdict keeps
    /// re-evaluating because adding nothing to the prompt cannot destabilize the head, and the
    /// clipboard may only become relevant once more text is typed. A new copy (change count) or a
    /// field switch (focus sequence) always re-evaluates. See `pinnedClipboardContext`.
    struct ClipboardPrefaceMemo {
        let focusSequence: UInt64
        let changeCount: Int
        let value: String?
    }

    var clipboardPrefaceMemo: ClipboardPrefaceMemo?
    /// Coalescing and monotonic-render state for engine partials. The coordinator owns scheduling
    /// and presentation; the value owns the stream's pure state transitions.
    var suggestionStreamingState = SuggestionStreamingState()

    /// Monotonic cancellation token for the "wait until the host publishes typed text to AX" loop.
    ///
    /// Keystrokes can arrive faster than Chromium publishes contenteditable updates. Without this
    /// token, every key starts its own delayed polling chain and those chains stack up, each doing
    /// synchronous `refreshNow()` calls on the main actor. Bumping the token makes older chains
    /// no-op before they can perform another expensive AX read.
    var hostPublishPollGeneration: UInt64 = 0
    /// Suppresses single-poll `Supported → Blocked → Supported` flicker on the same focused element
    /// so the overlay does not tear down and rebuild on every transient AX redraw. See
    /// `FocusCapabilityFlickerGate` for the rationale and the reproduction (Apple Calendar event
    /// editor).
    var capabilityFlickerGate = FocusCapabilityFlickerGate()
    /// Correlation ID for the most recently built `SuggestionRequest`. Stamped onto every
    /// state-transition log line so all events tied to one suggestion (debounce → generating →
    /// ready → accepted/rejected) can be joined with a single `jq` filter on `request_id`.
    /// `nil` between sessions; replaced when `+Prediction` builds the next request.
    var latestRequestID: String?
    /// Set when a full acceptance commits its final chunk; consumed by the next `apply`. Lets the
    /// coordinator drop a regeneration that only re-proposes the just-accepted tail before the host
    /// publishes the insert, the Chromium AX-publish race that otherwise loops accept/regenerate/
    /// accept on the last word. See `SuggestionSessionReconciler.isStaleAcceptanceEcho`.
    var lastAcceptedTail: AcceptedSuggestionTail?

    /// Wall-clock moment of the most recent committed acceptance. The stability gate uses its age
    /// to scope the backward-drift hold: only geometry read shortly after our own insert can be
    /// the stale-frame kind, so older backward corrections stay re-anchorable.
    var lastAcceptanceAt: Date?

    /// Bounded string-only memory of recent suggestions for instant re-show on rollback and
    /// re-entry (see `SuggestionAnchorCache`). `cotabbyAnchorReuseDisabled` is the kill switch.
    var suggestionAnchorCache = SuggestionAnchorCache()
    static let anchorReuseDisabledDefaultsKey = "cotabbyAnchorReuseDisabled"
    static let speculativePrefetchDisabledDefaultsKey = "cotabbySpeculativePrefetchDisabled"

    /// Content signature a speculative post-acceptance generation was built against. While set,
    /// `apply` may accept a result whose generation predates the live one as long as the live
    /// content matches this signature (the speculation bet paid off), and the host-publish poll
    /// stands down instead of scheduling a duplicate regeneration.
    var pendingSpeculativeSignature: String?

    /// Pure state for the bounded "keep owning Tab" window after a final-chunk acceptance. The
    /// coordinator continues to own the timer and input-monitor effects around these transitions.
    var postExhaustionAcceptanceState = PostExhaustionAcceptanceState()

    init(
        permissionManager: any SuggestionPermissionProviding,
        lowPowerModeProvider: any SuggestionLowPowerModeProviding,
        focusModel: any SuggestionFocusProviding,
        inputMonitor: any SuggestionInputMonitoring,
        overlayController: any SuggestionOverlayControlling,
        suggestionInserter: any SuggestionInserting,
        suggestionEngine: any SuggestionGenerating,
        suggestionSettings: any SuggestionSettingsProviding,
        clipboardContextProvider: any ClipboardContextProviding,
        clipboardRelevanceFilter: any ClipboardRelevanceFiltering,
        visualContextCoordinator: any VisualContextCoordinating,
        interactionState: SuggestionInteractionState,
        workController: SuggestionWorkController,
        configuration: SuggestionConfiguration,
        spellChecker: CurrentWordSpellChecker,
        symSpellCorrector: SymSpellCorrector,
        spellingLanguageResolver: SpellingLanguageResolver = SpellingLanguageResolver(),
        qualityMetricsStore: SuggestionQualityMetricsStore,
        userDefaults: UserDefaults = .standard
    ) {
        let storedTotalTabAcceptedWordCount = userDefaults.integer(
            forKey: Self.totalTabAcceptedWordCountDefaultsKey)

        self.permissionManager = permissionManager
        self.lowPowerModeProvider = lowPowerModeProvider
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.overlayController = overlayController
        self.suggestionInserter = suggestionInserter
        self.suggestionEngine = suggestionEngine
        self.suggestionSettings = suggestionSettings
        self.clipboardContextProvider = clipboardContextProvider
        self.clipboardRelevanceFilter = clipboardRelevanceFilter
        self.visualContextCoordinator = visualContextCoordinator
        self.interactionState = interactionState
        self.workController = workController
        self.configuration = configuration
        self.spellChecker = spellChecker
        self.symSpellCorrector = symSpellCorrector
        self.spellingLanguageResolver = spellingLanguageResolver
        self.qualityMetricsStore = qualityMetricsStore
        self.userDefaults = userDefaults
        settingsSnapshot = suggestionSettings.snapshot
        // These collaborators isolate "how overlay/logging works" from "when the coordinator
        // wants to show state," which keeps the coordinator closer to orchestration code.
        overlayPresenter = SuggestionOverlayPresenter(overlayController: overlayController)
        logger = SuggestionDebugLogger()
        totalTabAcceptedWordCount = max(storedTotalTabAcceptedWordCount, 0)
        visualContextStatus = visualContextCoordinator.status
        latestVisualContextText = visualContextCoordinator.latestExcerpt

        overlayState = overlayController.state

        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in
                self?.handleFocusSnapshotChange(snapshot)
            }
            .store(in: &cancellables)

        permissionManager.inputMonitoringGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        permissionManager.screenRecordingGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        lowPowerModeProvider.lowPowerModeChanges
            .sink { [weak self] _ in
                self?.handleLowPowerModeChange()
            }
            .store(in: &cancellables)

        // The monitor and overlay controller are callback-driven. The coordinator translates those
        // callbacks back into its state-machine methods.
        inputMonitor.onEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? false
        }

        inputMonitor.onSuppressedSyntheticInput = { [weak self] in
            self?.handleSuppressedSyntheticInput()
        }

        // Fail-open preflight for the active accept tap. The tap should only route a matching key
        // into the coordinator while there is visible suggestion UI. We deliberately do not require
        // `.ready` or even an active session here: a background refresh can move `state`, and if the
        // session has gone stale the coordinator still needs one chance to hide the stale overlay
        // before the tap passes the original key through.
        inputMonitor.shouldConsumeAcceptKeyProvider = { [weak self] in
            guard let self else { return false }
            // Keep owning the accept key through the brief post-acceptance regeneration window too,
            // even though the overlay is hidden then. Otherwise a fast follow-up Tab in that gap
            // falls through to the host app as a real Tab and focus jumps out of the field — the
            // "rapid Tab breaks, slow Tab is fine" report. See `armPostExhaustionAcceptance`.
            guard self.overlayState.isVisible || self.postExhaustionAcceptanceState.isArmed else { return false }
            return true
        }

        overlayController.onStateChange = { [weak self] state in
            guard let self else { return }
            self.overlayState = state
            // Only sit in the synchronous keystroke critical path while a suggestion is actually
            // visible. With the overlay hidden, Cotabby observes via a listen-only tap that does
            // not gate event delivery to other apps (issue #328).
            switch state {
            case .visible:
                self.inputMonitor.setAcceptInterceptionActive(true)
            case .hidden:
                self.inputMonitor.setAcceptInterceptionActive(false)
                // A hidden overlay ends any post-exhaustion Tab-ownership window. Every teardown and
                // abort path hides the overlay, so ending the window here is the single catch-all
                // that returns the accept key to the host (and cancels the backstop timer) once the
                // window is genuinely over. The `.exhausted` accept re-arms *after* its own
                // `hideOverlay` call, so this never cancels a window that was just opened.
                self.clearPostExhaustionAcceptanceWindow()
            }
        }

        visualContextCoordinator.onStateChange = { [weak self] status, excerpt in
            self?.visualContextStatus = status
            self?.latestVisualContextText = excerpt
        }

        visualContextCoordinator.onInjectedContextReady = { [weak self] identity in
            self?.schedulePredictionForCurrentFocusIfPossible(matching: identity)
        }

        suggestionSettings.snapshotPublisher
            .dropFirst()
            .sink { [weak self] snapshot in
                self?.handleSuggestionSettingsChange(snapshot)
            }
            .store(in: &cancellables)
    }

    /// Exposes the latest cancellation token for the split extension files.
    var currentWorkID: UInt64 {
        workController.currentWorkID
    }
}
