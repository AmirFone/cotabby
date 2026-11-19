import Combine
import CoreGraphics
import Foundation

/// File overview:
/// Defines the behavior-shaped contracts that `SuggestionCoordinator` depends on.
///
/// These protocols are intentionally narrow. The goal is not "abstract everything"; the goal is
/// to describe the coordinator's collaborators by the capabilities it actually needs:
/// permission reads, focus snapshots, input events, suggestion generation, text insertion, and
/// legacy visual-context lifecycle callbacks.
///
/// This is a high-leverage maintainability move because `SuggestionCoordinator` is the app's
/// largest orchestration type. Depending on contracts instead of concrete classes makes the data
/// flow easier to understand today and gives a natural seam for tests later without changing
/// runtime behavior now.
@MainActor
protocol SuggestionPermissionProviding: AnyObject {
    var inputMonitoringGranted: Bool { get }
    var screenRecordingGranted: Bool { get }
    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> { get }
    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> { get }
}

/// Supplies the initial Low Power Mode value separately from its changes-only stream.
@MainActor
protocol SuggestionLowPowerModeProviding: AnyObject {
    var isLowPowerModeEnabled: Bool { get }
    var lowPowerModeChanges: AnyPublisher<Bool, Never> { get }
}

@MainActor
protocol SuggestionFocusProviding: AnyObject {
    var snapshot: FocusSnapshot { get }
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { get }
    /// Milliseconds since the provider last completed a full AX capture, or `nil` when unknown.
    /// Each capture is a synchronous multi-IPC Accessibility walk, so hot-path consumers use this
    /// to skip a redundant capture that another caller performed moments earlier.
    var millisecondsSinceLastCapture: Int? { get }

    func refreshNow()

    /// Hint that Cotabby just mutated the focused field itself (synthetic insert or replace), so
    /// provider-side caches built from pre-mutation reads must not serve the next capture.
    /// Providers without such caches use the default no-op.
    func invalidateTransientCaretCaches()
}

extension SuggestionFocusProviding {
    /// Conservative default: age unknown, so `refreshIfStale` always refreshes. Production
    /// providers report a real age; test fakes can ignore freshness entirely.
    var millisecondsSinceLastCapture: Int? { nil }

    /// Default: nothing cached, nothing to invalidate.
    func invalidateTransientCaretCaches() {}

    /// Refreshes only when the last capture is older than `maxAgeMilliseconds`. The suggestion
    /// pipeline performs several captures per keystroke (host-publish poll, post-debounce check,
    /// result apply); when two of those land within one debounce window the second read cannot
    /// observe anything the first missed, so paying another synchronous AX walk buys nothing.
    func refreshIfStale(maxAgeMilliseconds: Int) {
        if let age = millisecondsSinceLastCapture, age <= maxAgeMilliseconds {
            return
        }

        refreshNow()
    }
}

@MainActor
protocol SuggestionInputMonitoring: AnyObject {
    var onEvent: ((CapturedInputEvent) -> Bool)? { get set }
    var onSuppressedSyntheticInput: (() -> Void)? { get set }

    /// Fail-open preflight for the active accept tap. The tap only routes a matching key into the
    /// coordinator when this closure returns `true` at event time. The coordinator still performs
    /// full session validation before the tap consumes the original key.
    var shouldConsumeAcceptKeyProvider: @MainActor @Sendable () -> Bool { get set }

    /// Drives the lifecycle of the active accept-key tap. The coordinator turns this on while
    /// a suggestion overlay is visible and off otherwise, so Cotabby only sits in the synchronous
    /// keystroke path during the brief windows it actually needs to consume the accept key.
    func setAcceptInterceptionActive(_ active: Bool)
}

/// The emoji picker's slice of the input monitor. Kept separate from `SuggestionInputMonitoring` so
/// the suggestion coordinator stays unaware of emoji concerns and vice versa, even though one
/// `InputMonitor` satisfies both.
@MainActor
protocol EmojiInputIntercepting: AnyObject {
    /// Per-key consume decision consulted by the active tap while an emoji capture is open. The
    /// controller computes the decision during the observer pass and this closure returns it.
    var emojiCaptureKeyDecider: (@MainActor (InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision)? { get set }

    /// Keeps the active tap installed for the emoji-capture reason (parallel to the suggestion
    /// overlay's `setAcceptInterceptionActive`).
    func setCaptureInterceptionActive(_ active: Bool)

    /// True when the key matches the user's configured word-accept binding. The emoji picker commits
    /// on this key so its commit stays consistent with accepting a suggestion word.
    func isWordAcceptKey(_ keyEvent: InputMonitorKeyEvent) -> Bool
}

@MainActor
protocol SuggestionGenerating: AnyObject {
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult
    /// Streaming variant: `onPartial` receives cumulative, already-normalized partial results on
    /// the main actor while the engine decodes, so ghost text can render after the first words
    /// instead of waiting for the full completion. The returned result remains the authoritative
    /// final answer; partials are best-effort hints the renderer may coalesce or drop. Engines
    /// that cannot stream rely on the default, which degrades to the single-shot path.
    func generateSuggestion(
        for request: SuggestionRequest,
        onPartial: (@MainActor (SuggestionResult) -> Void)?
    ) async throws -> SuggestionResult
    /// Clears backend-local continuation state when the focused editing context is no longer
    /// continuous. Stateless engines may implement this as a no-op.
    func resetCachedGenerationContext() async
    /// Best-effort warmup hook the coordinator calls after focus arrives on an editable surface.
    /// Apple Foundation Models primes its session here, and the llama engine prefills the new
    /// field's prompt KV (a focus change destroys the previous field's native sequence, so without
    /// this the first suggestion in every field pays the full cold prompt decode). Failures are
    /// intentionally swallowed by implementations because prewarming is opportunistic.
    func prewarm(for request: SuggestionRequest) async
}

extension SuggestionGenerating {
    func prewarm(for request: SuggestionRequest) async {}

    func generateSuggestion(
        for request: SuggestionRequest,
        onPartial: (@MainActor (SuggestionResult) -> Void)?
    ) async throws -> SuggestionResult {
        try await generateSuggestion(for: request)
    }
}

/// Behavior-shaped view of the llama runtime that `LlamaSuggestionEngine` depends on: run one
/// generation and drop the native KV cache. Extracted so the engine's failure handling — in
/// particular the invariant that a *cancelled* generation must NOT reset the cache (resetting it on
/// every superseded keystroke was the base-model input-lag regression) — can be unit-tested against
/// a fake runtime instead of loading a real model. `LlamaRuntimeManager` is the production conformer.
@MainActor
protocol LlamaRuntimeGenerating: AnyObject {
    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput
    /// Streaming variant: `onPartialRawText` receives the cumulative raw completion after each
    /// sampled token, called from the decode thread (hence `@Sendable`); callers own hopping to
    /// their actor. The returned output's text is still the authoritative final completion, and
    /// its confidence fields describe the whole generation (partials are pre-gate by nature).
    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions,
        onPartialRawText: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput
    func resetPromptCache()
    /// Decodes `prompt` into the native prompt cache without sampling any tokens, so the next
    /// `generate` whose prompt extends this one only decodes the typed delta. Best-effort warmup:
    /// callers treat failures as "no cache primed", never as a user-facing error.
    func prefill(prompt: String, cachedPrefixBytes: Int?, options: LlamaGenerationOptions) async throws
}

extension LlamaRuntimeGenerating {
    /// Default no-op so test fakes that only exercise the generate/cancel contract keep compiling;
    /// the production manager overrides this with a real prompt prefill.
    func prefill(prompt: String, cachedPrefixBytes: Int?, options: LlamaGenerationOptions) async throws {}
}

extension LlamaRuntimeGenerating {
    /// Default for fakes that only exercise the single-shot contract: ignore the partial hook.
    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions,
        onPartialRawText: (@Sendable (String) -> Void)?
    ) async throws -> LlamaGenerationOutput {
        try await generate(prompt: prompt, cachedPrefixBytes: cachedPrefixBytes, options: options)
    }
}

@MainActor
protocol SuggestionSettingsProviding: AnyObject {
    var snapshot: SuggestionSettingsSnapshot { get }
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> { get }
}

@MainActor
protocol ClipboardContextProviding: AnyObject {
    func currentContext() -> String?
    var currentChangeCount: Int { get }
}

@MainActor
protocol ClipboardRelevanceFiltering: AnyObject {
    /// Returns `clipboard` when it should be injected into the prompt, or `nil` to drop it.
    ///
    /// `precedingText` should be the same bounded window the downstream distiller will see,
    /// so the relevance gate and per-line distillation evaluate overlap consistently.
    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String?
}

@MainActor
protocol SuggestionInserting: AnyObject {
    var lastErrorMessage: String? { get }

    func insert(_ suggestion: String) -> Bool

    /// Presses Backspace `deletingUTF16Count` times and types `text` in one suppressed synthetic
    /// burst. The correction-acceptance path uses this to swap a typo'd word for the corrected word.
    /// `SuggestionInserter` already implements it (the emoji picker shares the same primitive).
    /// Despite its name the count is key presses, which equal UTF-16 units only for ASCII; see
    /// `BackspaceKeyCount` for text the writer typed.
    func replace(deletingUTF16Count: Int, with text: String) -> Bool
}

/// The emoji picker's slice of the inserter: replace a run of already-typed characters (the literal
/// `:query`) with the chosen glyph in one suppressed synthetic burst.
@MainActor
protocol EmojiTextInserting: AnyObject {
    func replace(deletingUTF16Count: Int, with text: String) -> Bool
}

/// Choices the writer can pick from near the caret: fixes for a misspelled word, or alternative
/// continuations for the ghost text. Produced by `SuggestionCoordinator`, shown by
/// `CandidateListController`.
struct CandidateOffer: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Replace `typo` (the trailing word) with the chosen candidate.
        case spelling(typo: String)
        /// Insert the chosen candidate at the caret.
        case continuation
    }

    let source: Source
    let candidates: [String]
    /// Per-candidate confidence in [0, 1] for spelling offers; empty for continuations.
    let scores: [Double]
    var caretRect: CGRect
    /// The field the offer is for. A variable because a field that only changes its frame gets a
    /// new number and keeps its bar (`CandidateListController.handleFocusSnapshot`).
    var focusChangeSequence: UInt64
    /// The row highlighted when the offer opens. Spelling bars put the typed word first and the
    /// best fix in the middle, like the iPhone keyboard, so they open on row 1.
    var preferredIndex = 0
    /// What to remember when the writer keeps the typed word (row 0 of a spelling bar), so the
    /// same word is not flagged again. Nil for continuations.
    var keepKey: String?
    /// The order came from Jev reading the sentence rather than from local evidence alone.
    var isContextRefined = false

    /// Spelling offers render as a horizontal three-slot bar; continuations as a vertical list.
    var isSpellingBar: Bool {
        if case .spelling = source { return true }
        return false
    }
}

/// What the review card shows: the sentence with the word under review marked, and its options with
/// the typed word first (in quotes), like the spelling bar.
struct SentenceReviewPresentation: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case plain
        /// Still to review, later in the sentence.
        case pending
        /// The word being decided now.
        case current
    }

    struct Piece: Equatable, Sendable {
        let text: String
        let role: Role
    }

    let pieces: [Piece]
    let options: [String]
    let selectedIndex: Int
    let position: Int
    let total: Int

    init(sentence: String, flags: [SentenceFlag], current: Int, selectedIndex: Int) {
        var pieces: [Piece] = []
        var cursor = sentence.startIndex
        for (index, flag) in flags.enumerated() {
            if cursor < flag.range.lowerBound {
                pieces.append(Piece(text: String(sentence[cursor..<flag.range.lowerBound]), role: .plain))
            }
            let role: Role = index == current ? .current : (index > current ? .pending : .plain)
            pieces.append(Piece(text: String(sentence[flag.range]), role: role))
            cursor = flag.range.upperBound
        }
        if cursor < sentence.endIndex {
            pieces.append(Piece(text: String(sentence[cursor...]), role: .plain))
        }
        self.pieces = pieces
        options = [flags[current].typed] + flags[current].options
        self.selectedIndex = selectedIndex
        position = current + 1
        total = flags.count
    }
}

/// The suggestion coordinator's handle on the candidate list. A visible list owns Up/Down/Tab/Return/
/// Escape until it closes; an armed offer stays invisible until the writer presses Down.
@MainActor
protocol CandidateOfferPresenting: AnyObject {
    var isShowingChoices: Bool { get }
    func presentChoices(_ offer: CandidateOffer)
    func armChoices(_ offer: CandidateOffer)
    func disarmChoices()
    func dismissChoices()
    func flashAutoCorrection(typo: String, correction: String, caretRect: CGRect)
}

/// The candidate list's slice of its floating panel, behind a protocol so the controller is testable
/// without an `NSPanel`.
@MainActor
protocol CandidateListPanelPresenting: AnyObject {
    var onSelectIndex: ((Int) -> Void)? { get set }
    var onClickOutside: (() -> Void)? { get set }

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String)
    func setSelectedIndex(_ index: Int)
    /// The next-word strip; `selectedIndex` is nil until the writer presses Tab. Clicking a word
    /// reports its index through `onSelectIndex`.
    func showWordStrip(words: [String], selectedIndex: Int?, caretRect: CGRect)
    func showFlash(typo: String, correction: String, caretRect: CGRect)
    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String)
    /// Briefly shows fixes that were already applied; not clickable, hides itself.
    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect)
    /// The step-through review of a finished sentence's unsure words. Clicking an option reports its
    /// index through `onSelectIndex`.
    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String)
    func hide()
}

/// An inline feature that can own keys while its panel is visible. `InlineCommandCoordinator` fans
/// keystrokes out to every participant and keeps the input monitor's single capture slot in sync.
@MainActor
protocol InlineCaptureParticipant: AnyObject {
    var isCapturing: Bool { get }
    var onCaptureStateChanged: (() -> Void)? { get set }
    func start()
    func stop()
    func observe(_ event: CapturedInputEvent) -> Bool
    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision
}

/// The suggestion coordinator's handle on the next-word strip. The coordinator only reports the text
/// before the caret after each keystroke settles; the presenter predicts, shows, and owns the keys.
@MainActor
protocol WordPredictionPresenting: AnyObject {
    /// True while the strip is on: it owns Tab, so ghost text is not generated.
    var replacesGhostText: Bool { get }
    func noteTypedText(_ precedingText: String, caretRect: CGRect, focusChangeSequence: UInt64)
    func hidePredictions()
    /// True when `precedingText` is the field as it stood a few keys ago: a host that has not yet
    /// told Accessibility about the writer's last keys. The presenter follows the keys themselves,
    /// so it is the one that can tell; the coordinator asks before it takes a read of the field
    /// for the text those keys left.
    func isBehindTheKeys(_ precedingText: String) -> Bool
}

/// The suggestion coordinator's handle on the per-sentence proofreading card.
@MainActor
protocol SentenceFixPresenting: AnyObject {
    var isShowingFix: Bool { get }
    /// Called on every prediction cycle with the live text before the caret.
    func noteTypedText(_ precedingText: String, caretRect: CGRect, focusChangeSequence: UInt64)
}

/// The emoji picker's slice of its floating panel: present/move/hide the match list. Behind a
/// protocol so `EmojiPickerController` can be unit-tested without constructing a real `NSPanel`.
@MainActor
protocol EmojiPickerPanelPresenting: AnyObject {
    var onSelectIndex: ((Int) -> Void)? { get set }
    var onClickOutside: (() -> Void)? { get set }

    func show(query: String, matches: [EmojiMatch], selectedIndex: Int, caretRect: CGRect)
    func setSelectedIndex(_ index: Int)
    func hide()
}

@MainActor
protocol SuggestionOverlayControlling: AnyObject {
    var state: OverlayState { get }
    var onStateChange: ((OverlayState) -> Void)? { get set }

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry)
    func hide(reason: String)

    /// Advances a visible single-line inline ghost to `remainingText` by sliding the panel right
    /// by the caret's travel for `insertedText` (the text that just landed in the host, whether
    /// Cotabby typed it or the user did). The slide reads the held overlay state, never a fresh AX
    /// caret, so it cannot jitter against AX noise. Returns `false` when the controller cannot
    /// safely slide (hidden, mirror mode, RTL, multi-line, or nothing rendered to measure
    /// against); callers then fall back to a caret-anchored present.
    func advanceInline(to remainingText: String, insertedText: String) -> Bool
}

extension SuggestionOverlayControlling {
    /// Default: not supported, so conformers that do not render an inline panel (e.g. test doubles)
    /// transparently fall back to the caret-anchored present path.
    func advanceInline(to remainingText: String, insertedText: String) -> Bool { false }
}

@MainActor
protocol VisualContextCoordinating: AnyObject {
    var status: VisualContextStatus { get }
    var latestExcerpt: String? { get }
    var onStateChange: ((VisualContextStatus, String?) -> Void)? { get set }
    var onInjectedContextReady: ((FocusedInputIdentity) -> Void)? { get set }

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot)
    /// Re-captures the screen for the field already being typed in when the last capture is stale.
    func refreshWhileTyping(for snapshotContext: FocusedInputSnapshot)
    func cancel(resetState: Bool)
    func excerpt(for context: FocusedInputContext) -> String?
}

extension VisualContextCoordinating {
    func refreshWhileTyping(for snapshotContext: FocusedInputSnapshot) {}
}
