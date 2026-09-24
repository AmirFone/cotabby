import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Proofreads each sentence right after the writer finishes it, in two stages:
///
/// - **Local, instant** (`LocalSentenceProofreader`): certain fixes (doubled words, punctuation
///   spacing, leftover typos with an unambiguous fix) are applied at once with a brief green flash;
///   likely wrong words are shown on a card with a dotted underline for the writer to review.
/// - **Groq, optional**: when a cloud endpoint is selected, the (locally fixed) sentence is then sent
///   for a grammar check and any fix is offered as the same card.
///
/// Word-level correction (`TypoGate`) only sees non-words. Real-word mistakes (`their`/`there`,
/// `form`/`from`), dropped words, and agreement errors need the whole sentence, which is exactly
/// what a fast hosted model can check in about 150 ms. The flow is deliberately quiet:
///
/// 1. `noteTypedText` runs on every prediction cycle. When the text before the caret ends with a
///    finished sentence plus the Space or Return that finished it, a check is scheduled after a short
///    pause so it never fires mid-burst.
/// 2. The response is shown only if every edit is confident and the field still ends with that exact
///    sentence. Otherwise nothing appears.
/// 3. While the card is up, Tab applies the fix and Escape dismisses it. Any other key dismisses it and
///    reaches the field normally, so the writer is never blocked.
///
/// `CotabbyAppEnvironment` owns one instance. It shares the input monitor's capture slot through
/// `InlineCommandCoordinator` and the rate budget with the autocomplete engine.
@MainActor
final class SentenceCheckController: SentenceFixPresenting, InlineCaptureParticipant {
    private enum Phase {
        case idle
        case waiting(sentence: String, task: Task<Void, Never>)
        case showing(FinishedSentence, corrected: String, focusChangeSequence: UInt64)
        case reviewing(Review)
    }

    /// Stepping through a sentence's unsure words one at a time. `choices[i]` is what flag `i` becomes.
    private struct Review {
        let finished: FinishedSentence
        let flags: [SentenceFlag]
        let focusChangeSequence: UInt64
        let caretRect: CGRect
        var current = 0
        var choices: [String] = []
        var selected = 1

        var presentation: SentenceReviewPresentation {
            SentenceReviewPresentation(sentence: finished.sentence, flags: flags, current: current, selectedIndex: selected)
        }
    }

    private enum KeyCode {
        static let left: CGKeyCode = 123
        static let right: CGKeyCode = 124
        static let digits: [CGKeyCode] = [18, 19, 20]
    }

    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    /// Long enough to skip a sentence the writer is still revising, short enough to land before the
    /// next sentence is well underway.
    static let idleDelayNanoseconds: UInt64 = 600_000_000
    static let minimumEditConfidence = 0.5
    private static let escapeKeyCode: CGKeyCode = 53

    private let panel: any CandidateListPanelPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inserter: any SuggestionInserting
    private let client: OpenAICompatibleAPIClient
    private let configurationProvider: () throws -> OpenAICompatibleEndpointConfiguration
    private let apiKeyProvider: () throws -> String?
    private let rateGovernor: EndpointRateGovernor?
    private let isEnabled: () -> Bool
    private let knownTerms: () -> String?
    private let acceptKeyLabel: () -> String
    private let isWordAcceptKey: (InputMonitorKeyEvent) -> Bool
    private let qualityMetricsStore: SuggestionQualityMetricsStore
    private let localProofread: (FinishedSentence) -> LocalProofreadResult?
    private let isLocalEnabled: () -> Bool
    private let appliesLocalFixes: () -> Bool

    private var phase: Phase = .idle
    private var pendingDecision: PendingDecision?
    private var checkedSentences: Set<String> = []
    private var locallyCheckedSentences: Set<String> = []
    private var checkedFocusChangeSequence: UInt64?

    var onCaptureStateChanged: (() -> Void)?
    /// Lets the suggestion coordinator clear ghost text so Tab has exactly one meaning.
    var onWillShowFix: (() -> Void)?
    var onCommitted: (() -> Void)?

    init(
        panel: any CandidateListPanelPresenting,
        focusModel: any SuggestionFocusProviding,
        inserter: any SuggestionInserting,
        client: OpenAICompatibleAPIClient,
        configurationProvider: @escaping () throws -> OpenAICompatibleEndpointConfiguration,
        apiKeyProvider: @escaping () throws -> String?,
        rateGovernor: EndpointRateGovernor?,
        isEnabled: @escaping () -> Bool,
        knownTerms: @escaping () -> String?,
        acceptKeyLabel: @escaping () -> String,
        isWordAcceptKey: @escaping (InputMonitorKeyEvent) -> Bool,
        qualityMetricsStore: SuggestionQualityMetricsStore,
        localProofread: @escaping (FinishedSentence) -> LocalProofreadResult? = { _ in nil },
        isLocalEnabled: @escaping () -> Bool = { false },
        appliesLocalFixes: @escaping () -> Bool = { false }
    ) {
        self.localProofread = localProofread
        self.isLocalEnabled = isLocalEnabled
        self.appliesLocalFixes = appliesLocalFixes
        self.panel = panel
        self.focusModel = focusModel
        self.inserter = inserter
        self.client = client
        self.configurationProvider = configurationProvider
        self.apiKeyProvider = apiKeyProvider
        self.rateGovernor = rateGovernor
        self.isEnabled = isEnabled
        self.knownTerms = knownTerms
        self.acceptKeyLabel = acceptKeyLabel
        self.isWordAcceptKey = isWordAcceptKey
        self.qualityMetricsStore = qualityMetricsStore
    }

    var isShowingFix: Bool {
        switch phase {
        case .showing, .reviewing: return true
        case .idle, .waiting: return false
        }
    }

    private var shownSentence: (FinishedSentence, UInt64)? {
        switch phase {
        case let .showing(finished, _, sequence): return (finished, sequence)
        case let .reviewing(review): return (review.finished, review.focusChangeSequence)
        case .idle, .waiting: return nil
        }
    }

    var isCapturing: Bool { isShowingFix }

    func start() {
        panel.onSelectIndex = { [weak self] index in
            guard let self else { return }
            if case .reviewing = self.phase {
                self.choose(index)
            } else {
                self.applyFix()
            }
        }
        panel.onClickOutside = { [weak self] in self?.hideCard() }
    }

    func stop() {
        cancelWaiting()
        hideCard()
    }

    // MARK: - Scheduling

    func noteTypedText(_ precedingText: String, caretRect: CGRect, focusChangeSequence: UInt64) {
        if let (finished, sequence) = shownSentence,
           sequence != focusChangeSequence || !precedingText.hasSuffix(finished.sentence + finished.trailingWhitespace) {
            hideCard()
        }
        if checkedFocusChangeSequence != focusChangeSequence {
            checkedFocusChangeSequence = focusChangeSequence
            checkedSentences = []
            locallyCheckedSentences = []
        }
        // A sentence that is no longer in the field (deleted, or the field was cleared after sending)
        // may be typed again and deserves a fresh check.
        checkedSentences = checkedSentences.filter { precedingText.contains($0) }
        locallyCheckedSentences = locallyCheckedSentences.filter { precedingText.contains($0) }
        guard let finished = FinishedSentenceExtractor.extract(from: precedingText) else {
            cancelWaiting()
            return
        }
        if isShowingFix {
            CotabbyLogger.suggestion.debug("Sentence pass skipped: a card is already showing")
        }
        if !isShowingFix, runLocalPass(on: finished, caretRect: caretRect, focusChangeSequence: focusChangeSequence) {
            cancelWaiting()
            return
        }
        guard isEnabled() else {
            cancelWaiting()
            return
        }
        guard !checkedSentences.contains(finished.sentence), !isShowingFix else { return }
        if case .waiting(let sentence, _) = phase, sentence == finished.sentence { return }

        cancelWaiting()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleDelayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.check(finished, focusChangeSequence: focusChangeSequence)
        }
        phase = .waiting(sentence: finished.sentence, task: task)
    }

    // MARK: - Local pass

    /// Runs the on-device pass once per sentence. Returns true when it acted (applied fixes or showed
    /// a card), in which case the cloud check waits for the corrected sentence.
    private func runLocalPass(on finished: FinishedSentence, caretRect: CGRect, focusChangeSequence: UInt64) -> Bool {
        guard isLocalEnabled(), locallyCheckedSentences.insert(finished.sentence).inserted else { return false }
        guard let result = localProofread(finished), result.hasAutoFixes || result.hasSuggestions else {
            CotabbyLogger.suggestion.debug("Sentence pass: nothing to fix in \(finished.sentence.count)-character sentence")
            return false
        }
        CotabbyLogger.suggestion.debug(
            "Sentence pass: \(result.hasAutoFixes ? "auto-fixes" : "no auto-fixes"), \(result.flags.count) word(s) to review"
        )
        guard result.hasAutoFixes, appliesLocalFixes() else {
            if result.hasAutoFixes {
                // Automatic fixing is off: the certain fixes are offered too, as one card.
                showCard(
                    for: finished,
                    corrected: result.suggested,
                    asSuggestions: true,
                    caretRect: caretRect,
                    focusChangeSequence: focusChangeSequence
                )
            } else {
                startReview(of: finished, flags: result.flags, caretRect: caretRect, focusChangeSequence: focusChangeSequence)
            }
            return true
        }
        let precedingText = focusModel.snapshot.context?.precedingText ?? ""
        guard SentenceRewritePlanner.plan(
            precedingText: precedingText,
            finished: finished,
            corrected: result.autoCorrected
        ) != nil else {
            return false
        }
        let corrected = FinishedSentence(
            sentence: result.autoCorrected,
            trailingWhitespace: finished.trailingWhitespace,
            precedingContext: finished.precedingContext
        )
        locallyCheckedSentences.insert(result.autoCorrected)
        // Deferred one turn, like every synthetic edit issued from inside a keystroke's handling.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Re-plan against a fresh read: if the writer typed on, the plan no longer matches and nothing changes.
            self.focusModel.refreshNow()
            guard let livePrecedingText = self.focusModel.snapshot.context?.precedingText,
                  let plan = SentenceRewritePlanner.plan(
                      precedingText: livePrecedingText,
                      finished: finished,
                      corrected: result.autoCorrected
                  ),
                  self.inserter.replace(deletingUTF16Count: plan.deletingUTF16Count, with: plan.replacementText) else {
                return
            }
            self.qualityMetricsStore.recordSentenceFixAccepted()
            self.focusModel.refreshNow()
            if result.hasSuggestions {
                self.startReview(
                    of: corrected,
                    flags: result.flags,
                    caretRect: self.focusModel.snapshot.context?.caretRect ?? caretRect,
                    focusChangeSequence: focusChangeSequence
                )
            } else {
                self.panel.showSentenceFlash(
                    segments: SentenceWordDiff.segments(original: finished.sentence, corrected: result.autoCorrected),
                    caretRect: self.focusModel.snapshot.context?.caretRect ?? caretRect
                )
            }
            self.onCommitted?()
        }
        return true
    }

    // MARK: - Review

    private func startReview(of finished: FinishedSentence, flags: [SentenceFlag], caretRect: CGRect, focusChangeSequence: UInt64) {
        guard !flags.isEmpty else { return }
        onWillShowFix?()
        let review = Review(finished: finished, flags: flags, focusChangeSequence: focusChangeSequence, caretRect: caretRect)
        phase = .reviewing(review)
        panel.showSentenceReview(review.presentation, caretRect: caretRect, acceptKeyLabel: acceptKeyLabel())
        qualityMetricsStore.recordSentenceFixOffered()
        onCaptureStateChanged?()
    }

    /// Keys while reviewing: Tab takes the highlighted option, Left/Right move, Option-1/2/3 pick,
    /// Escape keeps the typed word. Each decision moves to the next word; anything else closes the
    /// card and leaves the sentence as it is.
    private func observeReview(_ event: CapturedInputEvent, review: Review) -> Bool {
        let optionCount = review.flags[review.current].options.count + 1
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if modifiers == .option, let slot = KeyCode.digits.firstIndex(of: event.keyCode), slot < optionCount {
            choose(slot)
        } else if isWordAcceptKey(InputMonitorKeyEvent(keyCode: event.keyCode, flags: event.flags)) {
            choose(review.selected)
        } else if event.keyCode == Self.escapeKeyCode {
            choose(0)
        } else if event.keyCode == KeyCode.left || event.keyCode == KeyCode.right {
            var moved = review
            moved.selected = (review.selected + (event.keyCode == KeyCode.left ? -1 : 1) + optionCount) % optionCount
            phase = .reviewing(moved)
            panel.showSentenceReview(moved.presentation, caretRect: moved.caretRect, acceptKeyLabel: acceptKeyLabel())
        } else {
            hideCard()
            return false
        }
        pendingDecision = PendingDecision(keyCode: event.keyCode, consume: true)
        return true
    }

    /// Records option `index` for the current word (0 keeps what was typed) and moves on, applying
    /// the whole sentence once the last word is decided.
    private func choose(_ index: Int) {
        guard case .reviewing(var review) = phase else { return }
        let options = [review.flags[review.current].typed] + review.flags[review.current].options
        review.choices.append(options[min(max(index, 0), options.count - 1)])
        review.current += 1
        review.selected = 1
        guard review.current == review.flags.count else {
            phase = .reviewing(review)
            panel.showSentenceReview(review.presentation, caretRect: review.caretRect, acceptKeyLabel: acceptKeyLabel())
            return
        }
        hideCard()
        let finished = review.finished
        let corrected = review.flags.applying(choices: review.choices, to: finished.sentence)
        guard corrected != finished.sentence else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusModel.refreshNow()
            guard let precedingText = self.focusModel.snapshot.context?.precedingText,
                  let plan = SentenceRewritePlanner.plan(precedingText: precedingText, finished: finished, corrected: corrected),
                  self.inserter.replace(deletingUTF16Count: plan.deletingUTF16Count, with: plan.replacementText) else {
                return
            }
            self.qualityMetricsStore.recordSentenceFixAccepted()
            self.focusModel.refreshNow()
            self.onCommitted?()
        }
    }

    private func showCard(
        for finished: FinishedSentence,
        corrected: String,
        asSuggestions: Bool,
        caretRect: CGRect,
        focusChangeSequence: UInt64
    ) {
        onWillShowFix?()
        phase = .showing(finished, corrected: corrected, focusChangeSequence: focusChangeSequence)
        panel.showSentenceFix(
            segments: SentenceWordDiff.segments(original: finished.sentence, corrected: corrected, asSuggestions: asSuggestions),
            caretRect: caretRect,
            acceptKeyLabel: acceptKeyLabel()
        )
        qualityMetricsStore.recordSentenceFixOffered()
        onCaptureStateChanged?()
    }

    // MARK: - Cloud check

    private func check(_ finished: FinishedSentence, focusChangeSequence: UInt64) async {
        guard isStillCurrent(finished, focusChangeSequence: focusChangeSequence) else {
            phase = .idle
            return
        }
        checkedSentences.insert(finished.sentence)

        let result: SentenceCheckResult?
        do {
            guard try await admit() else {
                phase = .idle
                return
            }
            result = try await client.checkSentence(
                configuration: configurationProvider(),
                apiKey: apiKeyProvider(),
                sentence: finished.sentence,
                precedingContext: finished.precedingContext,
                knownTerms: knownTerms()
            )
            rateGovernor?.noteSuccess()
        } catch OpenAICompatibleClientError.rateLimited(let retryAfter, _) {
            rateGovernor?.noteRateLimited(retryAfterSeconds: retryAfter)
            phase = .idle
            return
        } catch {
            if !(error is CancellationError) {
                CotabbyLogger.suggestion.debug("Sentence check failed: \(error.localizedDescription)")
            }
            phase = .idle
            return
        }

        guard !Task.isCancelled,
              let result,
              result.edits.allSatisfy({ $0.confidence >= Self.minimumEditConfidence }),
              isStillCurrent(finished, focusChangeSequence: focusChangeSequence),
              let context = focusModel.snapshot.context,
              SentenceRewritePlanner.plan(precedingText: context.precedingText, finished: finished, corrected: result.corrected) != nil
        else {
            phase = .idle
            return
        }

        showCard(
            for: finished,
            corrected: result.corrected,
            asSuggestions: false,
            caretRect: context.caretRect,
            focusChangeSequence: focusChangeSequence
        )
        CotabbyLogger.llmIO.debug(
            "Sentence fix offered",
            metadata: [
                "original": .string(finished.sentence),
                "corrected": .string(result.corrected),
                "edits": .stringConvertible(result.edits.count)
            ]
        )
    }

    private func admit() async throws -> Bool {
        guard let rateGovernor else { return true }
        while true {
            switch rateGovernor.decide(estimatedTokens: 450, isAtWordBoundary: true) {
            case .send:
                return true
            case .wait(let seconds):
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            case .skip:
                return false
            }
        }
    }

    private func isStillCurrent(_ finished: FinishedSentence, focusChangeSequence: UInt64) -> Bool {
        guard let context = focusModel.snapshot.context,
              context.focusChangeSequence == focusChangeSequence,
              !context.isSecure else { return false }
        return context.precedingText.hasSuffix(finished.sentence + finished.trailingWhitespace)
    }

    private func cancelWaiting() {
        if case .waiting(_, let task) = phase {
            task.cancel()
            phase = .idle
        }
    }

    // MARK: - Keys

    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        pendingDecision = nil
        if case .reviewing(let review) = phase {
            return observeReview(event, review: review)
        }
        guard isShowingFix else { return false }
        if isWordAcceptKey(InputMonitorKeyEvent(keyCode: event.keyCode, flags: event.flags)) {
            applyFix()
            pendingDecision = PendingDecision(keyCode: event.keyCode, consume: true)
            return true
        }
        if event.keyCode == Self.escapeKeyCode {
            hideCard()
            pendingDecision = PendingDecision(keyCode: event.keyCode, consume: true)
            return true
        }
        hideCard()
        return false
    }

    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let pending = pendingDecision, pending.keyCode == keyEvent.keyCode else { return .notHandled }
        pendingDecision = nil
        return pending.consume ? .consume : .passThrough
    }

    // MARK: - Apply

    private func applyFix() {
        guard case .showing(let finished, let corrected, _) = phase else { return }
        hideCard()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let precedingText = self.focusModel.snapshot.context?.precedingText ?? ""
            guard let plan = SentenceRewritePlanner.plan(precedingText: precedingText, finished: finished, corrected: corrected) else {
                CotabbyLogger.suggestion.debug("Sentence fix skipped: the sentence changed before it was applied")
                return
            }
            guard self.inserter.replace(deletingUTF16Count: plan.deletingUTF16Count, with: plan.replacementText) else { return }
            self.qualityMetricsStore.recordSentenceFixAccepted()
            self.focusModel.refreshNow()
            self.onCommitted?()
        }
    }

    private func hideCard() {
        guard isShowingFix else { return }
        phase = .idle
        pendingDecision = nil
        panel.hide()
        onCaptureStateChanged?()
    }
}
