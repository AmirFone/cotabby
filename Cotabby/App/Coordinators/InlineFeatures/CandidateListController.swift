import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Owns the pick-one-of-a-few list that appears above the caret when Cotabby is not sure which word
/// the writer meant, and the Down-arrow list of alternative continuations behind a ghost suggestion.
///
/// It is a sibling of `EmojiPickerController`, not part of `SuggestionCoordinator`, for the same reason
/// the emoji picker is: a selectable panel with its own key ownership is a separate state machine from
/// ghost-text prediction. The coordinator decides *what* to offer (it runs the typo gate and the
/// engine); this controller decides how the writer navigates and commits it.
///
/// Key flow mirrors the emoji picker. `observe(_:)` gets first look at every keystroke through
/// `InlineCommandCoordinator` and records whether the active tap should swallow it; `decideCaptureKey`
/// returns that decision to the tap. While the list is visible it claims Up, Down, Tab, Return, and
/// Escape (and Left/Right for the horizontal spelling bar). Letters, Space, and Backspace pass through untouched so typing never stalls; the typo gate
/// then refreshes or dismisses the list on the next prediction cycle.
@MainActor
final class CandidateListController: CandidateOfferPresenting, InlineCaptureParticipant {
    private enum Phase: Equatable {
        case idle
        /// Offered but hidden behind a ghost suggestion until the writer presses Down.
        case armed(CandidateOffer)
        case showing(CandidateOffer)
    }

    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    private enum KeyCode {
        static let returnKey: CGKeyCode = 36
        static let keypadEnter: CGKeyCode = 76
        static let escape: CGKeyCode = 53
        static let left: CGKeyCode = 123
        static let right: CGKeyCode = 124
        static let down: CGKeyCode = 125
        static let up: CGKeyCode = 126
        /// Option+1…4 pick a slot directly, left to right.
        static let digits: [CGKeyCode] = [18, 19, 20, 21]
    }

    /// A list left alone this long closes itself so it never lingers over the writer's work.
    private static let idleTimeoutNanoseconds: UInt64 = 10_000_000_000

    private let panel: any CandidateListPanelPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inserter: any SuggestionInserting
    private let isWordAcceptKey: (InputMonitorKeyEvent) -> Bool
    private let acceptKeyLabel: () -> String
    private let correctionMemory: PersonalCorrectionMemory
    private let qualityMetricsStore: SuggestionQualityMetricsStore

    private var phase: Phase = .idle
    private var selectedIndex = 0
    /// Return commits a spelling bar only after the writer moved the highlight; otherwise it closes
    /// the bar and reaches the app, so sending a chat message never turns into a correction.
    private var hasNavigated = false
    private var pendingDecision: PendingDecision?
    private var idleTimeoutTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastCountedOffer: CandidateOffer.Source?

    /// Invoked when the list opens or closes so `InlineCommandCoordinator` can keep the input
    /// monitor's shared capture interception in sync.
    var onCaptureStateChanged: (() -> Void)?
    /// Invoked after a committed choice has been typed, so the suggestion pipeline re-reads the field.
    var onCommitted: (() -> Void)?
    /// Invoked when the writer closes the spelling bar with Escape, which means "leave this word alone".
    var onDismissedByEscape: (() -> Void)?
    /// Records picks and kept words for tuning (see `CorrectionJournal`). Nil in tests.
    var journal: CorrectionJournal?
    /// Told the field's expected text when a pick typed the word's space itself, so the word strip can
    /// keep a following period or Space from fighting it.
    var onPickAddedSpace: ((_ expectedText: String) -> Void)?

    init(
        panel: any CandidateListPanelPresenting,
        focusModel: any SuggestionFocusProviding,
        inserter: any SuggestionInserting,
        isWordAcceptKey: @escaping (InputMonitorKeyEvent) -> Bool,
        acceptKeyLabel: @escaping () -> String,
        correctionMemory: PersonalCorrectionMemory,
        qualityMetricsStore: SuggestionQualityMetricsStore
    ) {
        self.panel = panel
        self.focusModel = focusModel
        self.inserter = inserter
        self.isWordAcceptKey = isWordAcceptKey
        self.acceptKeyLabel = acceptKeyLabel
        self.correctionMemory = correctionMemory
        self.qualityMetricsStore = qualityMetricsStore
    }

    var isCapturing: Bool {
        if case .showing = phase { return true }
        return false
    }

    var isShowingChoices: Bool { isCapturing }

    func start() {
        panel.onSelectIndex = { [weak self] index in
            guard let self, case .showing(let offer) = self.phase, offer.candidates.indices.contains(index) else { return }
            self.selectedIndex = index
            self.commitSelection()
        }
        panel.onClickOutside = { [weak self] in
            self?.dismissChoices()
        }
        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleFocusSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        dismissChoices()
        cancellables.removeAll()
    }

    // MARK: - CandidateOfferPresenting

    func presentChoices(_ offer: CandidateOffer) {
        guard offer.candidates.count > 1 else {
            dismissChoices()
            return
        }
        let wasCapturing = isCapturing
        if case .showing(let current) = phase, current.source == offer.source, current.candidates == offer.candidates {
            selectedIndex = min(selectedIndex, offer.candidates.count - 1)
        } else {
            selectedIndex = min(max(offer.preferredIndex, 0), offer.candidates.count - 1)
            hasNavigated = false
        }
        phase = .showing(offer)
        panel.show(offer: offer, selectedIndex: selectedIndex, acceptKeyLabel: acceptKeyLabel())
        countOfferIfNew(offer)
        armIdleTimeout()
        if !wasCapturing {
            onCaptureStateChanged?()
        }
    }

    func armChoices(_ offer: CandidateOffer) {
        guard offer.candidates.count > 1, !isCapturing else { return }
        phase = .armed(offer)
    }

    func disarmChoices() {
        if case .armed = phase {
            phase = .idle
        }
    }

    func dismissChoices() {
        switch phase {
        case .idle:
            return
        case .armed:
            phase = .idle
        case .showing:
            teardown()
        }
    }

    func flashAutoCorrection(typo: String, correction: String, caretRect: CGRect) {
        guard !isCapturing else { return }
        panel.showFlash(typo: typo, correction: correction, caretRect: caretRect)
    }

    // MARK: - Keystroke observation

    /// Returns whether the list was involved with this key, so the suggestion coordinator stands down.
    @discardableResult
    func observe(_ event: CapturedInputEvent) -> Bool {
        pendingDecision = nil
        switch phase {
        case .idle:
            return false
        case .armed(let offer):
            guard event.keyCode == KeyCode.down, ShortcutModifierMask(eventFlags: event.flags).isEmpty else {
                phase = .idle
                return false
            }
            presentChoices(offer)
            hasNavigated = true
            if case .continuation = offer.source {
                qualityMetricsStore.recordAlternatesOpened()
            }
            record(consume: true, for: event)
            return true
        case .showing(let offer):
            return observeWhileShowing(event, offer: offer)
        }
    }

    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let pending = pendingDecision, pending.keyCode == keyEvent.keyCode else {
            return .notHandled
        }
        pendingDecision = nil
        return pending.consume ? .consume : .passThrough
    }

    private func observeWhileShowing(_ event: CapturedInputEvent, offer: CandidateOffer) -> Bool {
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if Self.belongsToTheApp(keyCode: event.keyCode, modifiers: modifiers) {
            teardown()
            return false
        }
        if modifiers == .option, KeyCode.digits.contains(event.keyCode) {
            return commitSlot(for: event, offer: offer)
        }
        if isWordAcceptKey(InputMonitorKeyEvent(keyCode: event.keyCode, flags: event.flags)) {
            commitSelection()
            record(consume: true, for: event)
            return true
        }
        switch event.keyCode {
        case KeyCode.up:
            moveSelection(by: -1, count: offer.candidates.count)
            record(consume: true, for: event)
            return true
        case KeyCode.down:
            moveSelection(by: 1, count: offer.candidates.count)
            record(consume: true, for: event)
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return handleReturn(event, offer: offer)
        case KeyCode.escape:
            if offer.isSpellingBar { onDismissedByEscape?() }
            teardown()
            record(consume: true, for: event)
            return true
        case KeyCode.left, KeyCode.right:
            return handleHorizontalArrow(event, offer: offer)
        default:
            armIdleTimeout()
            return false
        }
    }

    /// Keys the bar never takes: any shortcut with Command or Control, and Shift- or Option-arrows,
    /// which select text and jump by word.
    private static func belongsToTheApp(keyCode: CGKeyCode, modifiers: ShortcutModifierMask) -> Bool {
        if modifiers.contains(.command) || modifiers.contains(.control) { return true }
        let isArrow = [KeyCode.up, KeyCode.down, KeyCode.left, KeyCode.right].contains(keyCode)
        return isArrow && (modifiers.contains(.shift) || modifiers.contains(.option))
    }

    private func handleReturn(_ event: CapturedInputEvent, offer: CandidateOffer) -> Bool {
        guard hasNavigated || !offer.isSpellingBar else {
            teardown()
            return false
        }
        commitSelection()
        record(consume: true, for: event)
        return true
    }

    /// The spelling bar is horizontal, so Left/Right move along it; for the vertical list they are caret
    /// movement, which closes it.
    private func handleHorizontalArrow(_ event: CapturedInputEvent, offer: CandidateOffer) -> Bool {
        guard offer.isSpellingBar else {
            teardown()
            return false
        }
        moveSelection(by: event.keyCode == KeyCode.left ? -1 : 1, count: offer.candidates.count)
        record(consume: true, for: event)
        return true
    }

    /// Option+1…4: pick that slot without moving the highlight first.
    private func commitSlot(for event: CapturedInputEvent, offer: CandidateOffer) -> Bool {
        guard let slot = KeyCode.digits.firstIndex(of: event.keyCode), offer.candidates.indices.contains(slot) else {
            return false
        }
        selectedIndex = slot
        commitSelection()
        record(consume: true, for: event)
        return true
    }

    private func record(consume: Bool, for event: CapturedInputEvent) {
        pendingDecision = PendingDecision(keyCode: event.keyCode, consume: consume)
    }

    private func moveSelection(by delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
        hasNavigated = true
        panel.setSelectedIndex(selectedIndex)
        armIdleTimeout()
    }

    // MARK: - Commit

    private func commitSelection() {
        guard case .showing(let offer) = phase, offer.candidates.indices.contains(selectedIndex) else {
            teardown()
            return
        }
        let choice = offer.candidates[selectedIndex]
        let pickedRunnerUp = selectedIndex > 0
        teardown()
        // Posting synthetic keystrokes from inside the tap callback for the key being handled is what
        // made emoji commits flaky; defer one runloop turn exactly like `EmojiPickerController`.
        // Option+number picks must also wait for Option to be released, or the typed fix arrives as
        // Option+letters (see `ModifierRelease`).
        DispatchQueue.main.async { [weak self] in
            ModifierRelease.perform {
                self?.type(choice: choice, from: offer, pickedRunnerUp: pickedRunnerUp)
            }
        }
    }

    private func type(choice: String, from offer: CandidateOffer, pickedRunnerUp: Bool) {
        let precedingText = focusModel.snapshot.context?.precedingText ?? ""
        switch offer.source {
        case .spelling(let typo) where choice == typo:
            keep(typo: typo, offer: offer, precedingText: precedingText)
            return
        case .spelling(let typo):
            guard let plan = TypoCorrectionReplacementPlanner.plan(
                precedingText: precedingText,
                expectedTypo: typo,
                correctedWord: choice,
                requiresTrailingSpace: false
            ) else {
                CotabbyLogger.suggestion.debug("candidate commit skipped: the word to correct changed")
                return
            }
            // A word picked from the list is finished, so a mid-word pick also types the space the
            // writer would otherwise have to add.
            let addsSpace = !plan.replacementText.hasSuffix(" ")
            let text = addsSpace ? plan.replacementText + " " : plan.replacementText
            guard inserter.replace(deletingUTF16Count: plan.deletingUTF16Count, with: text) else { return }
            if addsSpace {
                onPickAddedSpace?(String(precedingText.utf16.dropLast(plan.deletingUTF16Count)).map { $0 + text } ?? "")
            }
            correctionMemory.recordAccepted(typo: typo, replacement: choice)
            qualityMetricsStore.recordCorrectionAccepted(fromList: true)
            journal?.record(.picked, typed: typo, final: choice)
        case .continuation:
            guard inserter.insert(choice) else { return }
            if pickedRunnerUp {
                qualityMetricsStore.recordAlternatePicked()
            }
        }
        focusModel.refreshNow()
        onCommitted?()
    }

    /// The quoted slot: leave the word alone, finish it with a space if the caret is still inside
    /// it, and stop flagging it.
    private func keep(typo: String, offer: CandidateOffer, precedingText: String) {
        correctionMemory.recordKept(offer.keepKey ?? typo)
        journal?.record(.keptAsTyped, typed: typo, final: typo, offered: offer.candidates.first { $0 != typo })
        if precedingText.hasSuffix(typo) {
            _ = inserter.insert(" ")
        }
        focusModel.refreshNow()
        onCommitted?()
    }

    // MARK: - Lifecycle

    private func teardown() {
        let wasCapturing = isCapturing
        phase = .idle
        selectedIndex = 0
        hasNavigated = false
        pendingDecision = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        panel.hide()
        if wasCapturing {
            onCaptureStateChanged?()
        }
    }

    private func countOfferIfNew(_ offer: CandidateOffer) {
        guard case .spelling = offer.source, lastCountedOffer != offer.source else { return }
        lastCountedOffer = offer.source
        qualityMetricsStore.recordCorrectionOffered()
    }

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        switch phase {
        case .idle:
            return
        case .armed(let offer):
            if snapshot.context?.focusChangeSequence != offer.focusChangeSequence {
                phase = .idle
            }
        case .showing(let offer):
            guard let context = snapshot.context,
                  !context.isSecure,
                  context.focusChangeSequence == offer.focusChangeSequence else {
                teardown()
                return
            }
            // Most focus updates repeat the caret position; only a move needs the panel placed again.
            guard context.caretRect != offer.caretRect else { return }
            var moved = offer
            moved.caretRect = context.caretRect
            phase = .showing(moved)
            panel.show(offer: moved, selectedIndex: selectedIndex, acceptKeyLabel: acceptKeyLabel())
        }
    }

    private func armIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: CandidateListController.idleTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.teardown()
        }
    }
}
