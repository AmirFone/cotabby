import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Owns the next-word strip: up to five likely words shown above the caret while typing. Tab types
/// the first (most likely) word and the strip at once predicts the word after it, so a sentence can
/// be built by pressing Tab instead of spelling each word; Option+2…5 type the others. Tab means
/// "yes, that" everywhere: here, on the spelling bar, and on the sentence card. Return and Escape
/// reach the app (Escape also hides the strip until the next word).
///
/// The arrow keys move the highlight, as they do on the spelling bar and the sentence card: Right
/// steps to the next word, Left steps back, and Tab or Return then types the highlighted word. The
/// strip is on screen most of the time, so it only takes an arrow when the app has no use for it:
/// Right when nothing follows the caret on its line (the caret could not move right anyway), and
/// Left only after Right has moved the highlight. Everywhere else the arrows stay caret movement and
/// hide the strip, and Up and Down always do.
///
/// Why this layout: simulated on 3,000 held-out sentences (`cotabby-spell --ksr`, `UI_COST`), one key
/// for word 1 plus a chord for the rest saves 51% of keystrokes; the earlier Tab-to-highlight then
/// Return design saved 26%, because every pick cost at least two keys.
///
/// It is its own controller, not a mode of `CandidateListController`, because its lifecycle is the
/// opposite of that list's: the spelling bar is an interruption that owns navigation keys until the
/// writer decides, while the strip is ambient and visible most of the time. The spelling bar and the
/// sentence card are earlier capture participants, so while either is up it gets Tab first; the
/// typo gate also hides the strip whenever a word needs fixing. While predictions are on the strip
/// replaces ghost text (`replacesGhostText`), so Tab has exactly one meaning.
///
/// Data flow: `SuggestionCoordinator` calls `noteTypedText` after each keystroke settles and the
/// typo gate lets the word through; this controller predicts (`NextWordPredictor` through the
/// injected closure), shows or hides the strip, learns finished sentences into
/// `PersonalPhraseModel`, and types a picked word through the shared inserter.
@MainActor
final class WordPredictionController: WordPredictionPresenting, InlineCaptureParticipant {
    struct Showing: Equatable {
        let prediction: NextWordPrediction
        var caretRect: CGRect
        let focusChangeSequence: UInt64
        /// A key was typed since this prediction; the field has moved on and it must be recomputed
        /// before a pick.
        var isStale = false
    }

    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    private enum KeyCode {
        static let returnKey: CGKeyCode = 36
        static let keypadEnter: CGKeyCode = 76
        static let escape: CGKeyCode = 53
        static let space: CGKeyCode = 49
        static let delete: CGKeyCode = 51
        static let tab: CGKeyCode = 48
        static let left: CGKeyCode = 123
        static let right: CGKeyCode = 124
        static let arrows: Set<CGKeyCode> = [123, 124, 125, 126]
        /// Option+1…5, left to right.
        static let digits: [CGKeyCode] = [18, 19, 20, 21, 23]
    }

    /// A strip left alone this long goes away so it never sits over the writer's reading.
    private static let idleTimeoutNanoseconds: UInt64 = 8_000_000_000

    private let panel: any CandidateListPanelPresenting
    private let focusModel: any SuggestionFocusProviding
    private let inserter: any SuggestionInserting
    private let predict: (String) -> NextWordPrediction?
    private let isEnabled: () -> Bool
    private let learn: (String) -> Void
    /// True when the spelling gate has already decided to fix, or put its bar on, the word the
    /// last key produced.
    private let isSpellingPending: () -> Bool
    /// How long a finished sentence must stay in the field unchanged before it is learned.
    private let learnDelay: TimeInterval
    /// True while the language model is working on its answer for this text (see `showOrAwait`).
    private let isLanguageModelPending: (String) -> Bool
    /// The longest the strip waits for that answer before showing the table's order instead.
    private let languageModelWait: TimeInterval

    private(set) var showing: Showing?
    /// The slot the writer moved the highlight to with the arrow keys; nil until they do, and again
    /// as soon as the strip shows different words.
    private(set) var arrowedSlot: Int?
    private var pendingDecision: PendingDecision?
    /// Escape hides the strip until the next word starts.
    private var isSuppressed = false
    private var lastLearnedSentence: String?
    /// The text before the caret at the last settled keystroke; read when Return sends a line.
    private var lastNotedText = ""
    /// Uptime of the last key seen, for the key-to-strip latency in the debug log.
    private var lastKeyUptimeNanoseconds: UInt64?
    /// The text before the caret that the strip on screen was predicted for. It can be a key ahead
    /// of `lastNotedText` (see `predictAhead`); a redraw must predict for the same text.
    private var shownText = ""
    /// A strip that is ready to draw but waiting for the language model's order (`showOrAwait`).
    private var awaited: (showing: Showing, text: String)?
    private var awaitTimeout: DispatchWorkItem?
    /// Keys seen since the last settled text; the optimistic update only trusts exactly one.
    private var keysSinceNote = 0
    /// The field's text right after a pick typed a word and its space; cleared by the next key.
    private var pickedText: String?
    private var idleTimeoutTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    var onCaptureStateChanged: (() -> Void)?
    /// Invoked after a picked word has been typed, so the suggestion pipeline re-reads the field.
    var onCommitted: (() -> Void)?
    /// A sentence the writer finished and left standing (it was still in the field, unchanged, after
    /// `learnDelay`, so any fix made to it had already landed), or a chat line sent with Return.
    /// The opt-in training record listens here.
    var onSentenceSettled: ((String) -> Void)?

    init(
        panel: any CandidateListPanelPresenting,
        focusModel: any SuggestionFocusProviding,
        inserter: any SuggestionInserting,
        predict: @escaping (String) -> NextWordPrediction?,
        isEnabled: @escaping () -> Bool,
        learn: @escaping (String) -> Void,
        isSpellingPending: @escaping () -> Bool = { false },
        learnDelay: TimeInterval = 0.8,
        isLanguageModelPending: @escaping (String) -> Bool = { _ in false },
        languageModelWait: TimeInterval = 0.05
    ) {
        self.isSpellingPending = isSpellingPending
        self.learnDelay = learnDelay
        self.isLanguageModelPending = isLanguageModelPending
        self.languageModelWait = languageModelWait
        self.panel = panel
        self.focusModel = focusModel
        self.inserter = inserter
        self.predict = predict
        self.isEnabled = isEnabled
        self.learn = learn
    }

    var isCapturing: Bool { showing != nil }

    func start() {
        panel.onSelectIndex = { [weak self] index in
            self?.commit(slot: index)
        }
        panel.onClickOutside = { [weak self] in
            self?.hide(because: "a click outside it")
        }
        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in self?.handleFocusSnapshot(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        hide(because: "the controller stopped")
        cancellables.removeAll()
    }

    // MARK: - WordPredictionPresenting

    func noteTypedText(_ precedingText: String, caretRect: CGRect, focusChangeSequence: UInt64) {
        keysSinceNote = 0
        lastNotedText = precedingText
        learnFinishedSentence(in: precedingText)
        guard isEnabled(), !isSuppressed, let prediction = predict(precedingText) else {
            hide(because: "nothing to predict for this text")
            return
        }
        showOrAwait(Showing(prediction: prediction, caretRect: caretRect, focusChangeSequence: focusChangeSequence), for: precedingText)
    }

    /// Shows the strip now, or holds it for a moment when the language model is about to say which
    /// order the words belong in.
    ///
    /// Why wait: the table answers in under a millisecond and the model about 20 ms later. Drawing
    /// both would put one word in the first slot and swap it for another before the writer has
    /// finished reading it. The strip already on screen stays as it is during the wait (it is marked
    /// stale, so a pick re-reads the field), and if the model takes longer than `languageModelWait`
    /// the table's order is shown after all. The model only has to be waited for once per word: the
    /// letters typed afterwards reuse its answer.
    private func showOrAwait(_ next: Showing, for text: String) {
        awaitTimeout?.cancel()
        guard isLanguageModelPending(text) else {
            awaited = nil
            show(next, for: text)
            return
        }
        awaited = (next, text)
        let timeout = DispatchWorkItem { [weak self] in self?.showAwaited() }
        awaitTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + languageModelWait, execute: timeout)
    }

    /// Draws the strip that was held back, predicted again so it has the model's order if the
    /// answer came in the meantime.
    private func showAwaited() {
        awaitTimeout?.cancel()
        awaitTimeout = nil
        guard let held = awaited else { return }
        awaited = nil
        var next = held.showing
        if let prediction = predict(held.text) {
            next = Showing(
                prediction: prediction, caretRect: next.caretRect,
                focusChangeSequence: next.focusChangeSequence, isStale: next.isStale
            )
        }
        show(next, for: held.text)
    }

    /// The language model has a new answer (`WordLanguageModelService.onReady`). A strip that was
    /// waiting for it is drawn. One already on screen is drawn again if the order changed, unless
    /// the writer has moved the highlight: the words must not change under it.
    func redrawWithLanguageModel() {
        if awaited != nil {
            showAwaited()
            return
        }
        guard let current = showing, arrowedSlot == nil, pendingDecision == nil,
              let prediction = predict(shownText), prediction.words != current.prediction.words else { return }
        var next = Showing(prediction: prediction, caretRect: current.caretRect, focusChangeSequence: current.focusChangeSequence)
        next.isStale = current.isStale
        show(next, for: shownText)
    }

    var replacesGhostText: Bool { isEnabled() }

    func hidePredictions() {
        hide(because: "another part of Cotabby asked")
    }

    /// `reason` goes to the debug log: a strip that is gone when Tab is pressed types a tab into the
    /// writer's text, and the log has to say which of the many reasons took it down.
    private func hide(because reason: String) {
        if showing != nil { CotabbyLogger.suggestion.debug("Word strip hidden: \(reason)") }
        awaitTimeout?.cancel()
        awaitTimeout = nil
        awaited = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        pendingDecision = nil
        arrowedSlot = nil
        guard showing != nil else { return }
        showing = nil
        panel.hide()
        onCaptureStateChanged?()
    }

    // MARK: - Keys

    func observe(_ event: CapturedInputEvent) -> Bool {
        pendingDecision = nil
        lastKeyUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        if [KeyCode.space, KeyCode.returnKey, KeyCode.keypadEnter].contains(event.keyCode) {
            isSuppressed = false
        }
        // Return on a word the writer arrowed to types that word; it does not send the line.
        if event.keyCode == KeyCode.returnKey, arrowedSlot == nil,
           event.flags.isDisjoint(with: [.maskShift, .maskCommand, .maskAlternate, .maskControl]) {
            learnSentLine()
        }
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if claimPunctuationAfterPick(event, modifiers: modifiers) { return true }
        guard showing != nil else { return false }
        if modifiers == .option, let slot = KeyCode.digits.firstIndex(of: event.keyCode) {
            return claim(event) { ModifierRelease.perform { self.commit(slot: slot) } }
        }
        guard modifiers.isEmpty || modifiers == .shift else {
            hide(because: "a shortcut key")
            return false
        }
        if modifiers.isEmpty, claimPickingKey(event) { return true }
        switch event.keyCode {
        case KeyCode.escape:
            isSuppressed = true
            hide(because: "Escape")
            return false
        case let code where KeyCode.arrows.contains(code) || code == KeyCode.returnKey || code == KeyCode.keypadEnter:
            hide(because: "an arrow or Return the strip does not take")
            return false
        default:
            showing?.isStale = true
            predictAhead(of: event)
            return false
        }
    }

    /// Updates the strip from the key itself instead of waiting 30–100 ms for the host to publish it
    /// to Accessibility: the last settled text plus this one character (or minus one, for Delete).
    /// Only the first key after a settled read is trusted, so a burst never compounds guesses. The
    /// strip stays marked stale, so a pick still re-reads the field first, and the real prediction
    /// cycle replaces this one moments later.
    private func predictAhead(of event: CapturedInputEvent) {
        keysSinceNote += 1
        guard keysSinceNote == 1, let current = showing, event.kind == .textMutation else { return }
        // The spelling gate is about to fix this word or put its bar up, and either one hides this
        // strip. Redrawing it here would show for a few milliseconds and be thrown away, and the
        // redraw (a window-server round trip) is main-thread time taken from the fix itself.
        guard !isSpellingPending() else { return }
        let text: String
        if event.keyCode == KeyCode.delete {
            guard !lastNotedText.isEmpty else { return }
            text = String(lastNotedText.dropLast())
        } else {
            guard event.characters.count == 1, let character = event.characters.first,
                  character.isLetter || character == " " || character == "'" else { return }
            text = lastNotedText + event.characters
        }
        guard let prediction = predict(text) else { return }
        showOrAwait(
            Showing(prediction: prediction, caretRect: current.caretRect, focusChangeSequence: current.focusChangeSequence, isStale: true),
            for: text
        )
    }

    func decideCaptureKey(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard let pending = pendingDecision, pending.keyCode == keyEvent.keyCode else {
            return .notHandled
        }
        pendingDecision = nil
        return pending.consume ? .consume : .passThrough
    }

    /// The unmodified keys that pick from the strip: Tab types the highlighted word, Right and Left
    /// move the highlight when the app has no use for them (see the file overview), and Return
    /// types the highlighted word once the arrows have moved it.
    private func claimPickingKey(_ event: CapturedInputEvent) -> Bool {
        let hasArrowed = arrowedSlot != nil
        switch event.keyCode {
        case KeyCode.tab where tabTakesWord || hasArrowed:
            return claimHighlightedWord(event)
        // `where` binds to one pattern only, so each key carries its own condition.
        case KeyCode.returnKey where hasArrowed, KeyCode.keypadEnter where hasArrowed:
            return claimHighlightedWord(event)
        case KeyCode.right where hasArrowed || caretEndsItsLine:
            moveHighlight(by: 1)
            return claim(event) {}
        case KeyCode.left where hasArrowed:
            moveHighlight(by: -1)
            return claim(event) {}
        default:
            return false
        }
    }

    private func redraw() {
        guard let current = showing else { return }
        panel.showWordStrip(
            words: current.prediction.words,
            selectedIndex: arrowedSlot ?? (tabTakesWord ? 0 : nil),
            caretRect: current.caretRect
        )
    }

    /// Nothing follows the caret on its line, so the Right arrow has nowhere to take it and can
    /// move the highlight instead. With text to the right the key stays caret movement.
    private var caretEndsItsLine: Bool {
        guard let next = focusModel.snapshot.context?.trailingText.first else { return true }
        return next.isNewline
    }

    /// Steps the highlight along the strip, wrapping at either end. The first Right goes to the
    /// second word where Tab already means the first, and to the first word where nothing is
    /// highlighted yet (single-line fields and code editors).
    private func moveHighlight(by delta: Int) {
        guard let words = showing?.prediction.words, !words.isEmpty else { return }
        let current = arrowedSlot ?? (tabTakesWord ? 0 : -1)
        let next = (current + delta + words.count) % words.count
        arrowedSlot = next
        panel.setSelectedIndex(next)
        armIdleTimeout()
    }

    /// Tab or Return on the highlighted word. The word itself is carried, not its slot: if keys
    /// typed since the strip was drawn change its words, a slot number would pick a word the writer
    /// never saw highlighted.
    private func claimHighlightedWord(_ event: CapturedInputEvent) -> Bool {
        guard let words = showing?.prediction.words, words.indices.contains(arrowedSlot ?? 0) else { return false }
        let word = words[arrowedSlot ?? 0]
        return claim(event) {
            self.refreshIfStale()
            guard let slot = self.showing?.prediction.words.firstIndex(of: word) else { return }
            self.commit(slot: slot)
        }
    }

    /// Records that the tap should swallow this key and runs `action` one runloop turn later: posting
    /// synthetic keys from inside the tap callback for the key being handled is unreliable (see
    /// `EmojiPickerController`).
    private func claim(_ event: CapturedInputEvent, action: @escaping () -> Void) -> Bool {
        pendingDecision = PendingDecision(keyCode: event.keyCode, consume: true)
        DispatchQueue.main.async(execute: action)
        return true
    }

    /// Keys typed since the strip was computed are in the field but not in the strip; re-read the
    /// field so a pick never lands on a prefix the writer has already extended.
    private func refreshIfStale() {
        guard let current = showing, current.isStale else { return }
        focusModel.refreshNow()
        guard let context = focusModel.snapshot.context,
              context.focusChangeSequence == current.focusChangeSequence,
              let prediction = predict(context.precedingText) else {
            hide(because: "the field changed before a pick and nothing fits it now")
            return
        }
        show(
            Showing(prediction: prediction, caretRect: context.caretRect, focusChangeSequence: current.focusChangeSequence),
            for: context.precedingText
        )
    }

    // MARK: - Commit

    private func commit(slot: Int) {
        refreshIfStale()
        guard let current = showing, current.prediction.words.indices.contains(slot) else { return }
        let word = current.prediction.words[slot]
        let prefix = current.prediction.prefix
        let precedingText = focusModel.snapshot.context?.precedingText ?? ""
        guard precedingText.hasSuffix(prefix) else {
            hide(because: "the field no longer ends with the typed letters")
            return
        }
        let inserted = prefix.isEmpty
            ? inserter.insert(word + " ")
            : inserter.replace(deletingUTF16Count: prefix.utf16.count, with: word + " ")
        guard inserted else {
            hide(because: "the pick could not be typed")
            return
        }
        // Predict the following word from the text the field is about to hold, so the next pick is
        // available before the host has even published this one.
        let expected = String(precedingText.dropLast(prefix.count)) + word + " "
        pickedText = expected
        if let next = predict(expected) {
            show(Showing(prediction: next, caretRect: current.caretRect, focusChangeSequence: current.focusChangeSequence), for: expected)
        } else {
            hide(because: "nothing to predict after the pick")
        }
        focusModel.invalidateTransientCaretCaches()
        onCommitted?()
    }

    static let closingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    /// Another panel (the spelling bar) typed a word and its space; treat the next key like one after
    /// a strip pick.
    func notePickAddedSpace(expectedText: String) {
        guard !expectedText.isEmpty else { return }
        pickedText = expectedText
    }

    /// Claims the very next key after a pick when it would fight the space the pick added: a closing
    /// mark moves in front of it (see `movePickSpace`), and a Space is swallowed, since the habit of
    /// pressing Space after a word would otherwise leave two.
    private func claimPunctuationAfterPick(_ event: CapturedInputEvent, modifiers: ShortcutModifierMask) -> Bool {
        guard let picked = pickedText else { return false }
        pickedText = nil
        if event.keyCode == KeyCode.space, modifiers.isEmpty {
            return claim(event) {}
        }
        guard modifiers.isEmpty || modifiers == .shift, event.characters.count == 1,
              let mark = event.characters.first, Self.closingPunctuation.contains(mark) else { return false }
        return claim(event) { self.movePickSpace(after: mark, expected: picked) }
    }

    /// Punctuation typed right after a pick belongs against the word, not after the space the pick
    /// added: `necessary .` becomes `necessary. `, as on a phone keyboard. Waits for the pick's own
    /// keys to land, and only moves the space if the field still ends exactly as the pick left it;
    /// otherwise the mark is typed as is.
    private func movePickSpace(after mark: Character, expected: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + SyntheticEventPoster.secondsUntilSettled + 0.01) { [weak self] in
            guard let self else { return }
            self.focusModel.refreshNow()
            let text = self.focusModel.snapshot.context?.precedingText ?? ""
            let moved = text.hasSuffix(" ") && expected.hasSuffix(String(text.suffix(min(text.count, 24))))
                && self.inserter.replace(deletingUTF16Count: 1, with: String(mark) + " ")
            if !moved {
                _ = self.inserter.insert(String(mark))
            }
            self.focusModel.invalidateTransientCaretCaches()
            self.onCommitted?()
        }
    }

    // MARK: - Learning

    /// When the text ends with a finished sentence, feeds it to the personal model once, after
    /// `learnDelay` and only if the field still holds it as written: the sentence pass fixes a
    /// finished sentence moments later (`the the` → `the`), and learning before that would teach
    /// the mistake. A fixed sentence arrives here again as a new sentence and is learned instead.
    /// Sentences with words the dictionary does not know are skipped by the learner's caller.
    private func learnFinishedSentence(in text: String) {
        guard text.last?.isWhitespace == true else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let terminator = trimmed.last, ".!?".contains(terminator) else { return }
        let body = trimmed.dropLast()
        let start = body.lastIndex { ".!?\n".contains($0) }.map { body.index(after: $0) } ?? body.startIndex
        let sentence = body[start...].trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty, sentence != lastLearnedSentence else { return }
        lastLearnedSentence = sentence
        // The sentence as the sentence pass sees it (punctuation kept, abbreviation-aware), so a
        // listener can match it against that pass's fixes. Nil for text the pass leaves alone.
        let finished = FinishedSentenceExtractor.extract(from: text)?.sentence
        DispatchQueue.main.asyncAfter(deadline: .now() + learnDelay) { [weak self] in
            guard let self, self.focusModel.snapshot.context?.precedingText.contains(sentence) == true else { return }
            self.learn(sentence)
            if let finished { self.onSentenceSettled?(finished) }
        }
    }

    /// A chat line sent with Return usually has no period, so it would never count as finished;
    /// Return ends it. Learned at once because the field is often cleared on send.
    private func learnSentLine() {
        let line = lastNotedText.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let start = line.lastIndex { ".!?".contains($0) }.map { line.index(after: $0) } ?? line.startIndex
        let sentence = line[start...].trimmingCharacters(in: .whitespaces)
        guard sentence.split(separator: " ").count >= 3, sentence != lastLearnedSentence else { return }
        lastLearnedSentence = sentence
        learn(sentence)
        onSentenceSettled?(sentence)
    }

    /// Where Tab already means something the writer relies on, the strip leaves it alone and every
    /// word takes Option+number: single-line fields (Tab moves to the next field) and code editors
    /// (Tab indents).
    private var tabTakesWord: Bool {
        guard let context = focusModel.snapshot.context else { return true }
        return !Self.isSingleLine(role: context.role, subrole: context.subrole)
            && AppSurfaceClassifier.classify(bundleIdentifier: context.bundleIdentifier) != .codeEditor
    }

    static func isSingleLine(role: String, subrole: String?) -> Bool {
        ["AXTextField", "AXSearchField", "AXComboBox"].contains(role) || subrole == "AXSearchField"
    }

    // MARK: - Presentation

    private func show(_ next: Showing, for text: String) {
        let wasCapturing = isCapturing
        shownText = text
        if next.prediction.words != showing?.prediction.words {
            arrowedSlot = nil
        }
        showing = next
        redraw()
        if let keyTime = lastKeyUptimeNanoseconds {
            lastKeyUptimeNanoseconds = nil
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - keyTime) / 1_000_000
            CotabbyLogger.suggestion.debug("Word strip shown \(String(format: "%.1f", elapsed)) ms after the key")
        }
        armIdleTimeout()
        if !wasCapturing {
            onCaptureStateChanged?()
        }
    }

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        guard let current = showing else {
            if snapshot.context == nil { isSuppressed = false }
            return
        }
        guard let context = snapshot.context,
              !context.isSecure,
              context.focusChangeSequence == current.focusChangeSequence else {
            isSuppressed = false
            hide(because: "focus moved")
            return
        }
        guard context.caretRect != current.caretRect else { return }
        showing?.caretRect = context.caretRect
        redraw()
    }

    private func armIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: WordPredictionController.idleTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.hide(because: "left alone too long")
        }
    }
}

extension WordPredictionController {
    /// The bundled list of words with many recorded misspellings (`commonly_misspelled_en.txt`).
    static func commonlyMisspelledWords(in bundle: Bundle = .main) -> Set<String> {
        guard let url = bundle.url(forResource: "commonly_misspelled_en", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(contents.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
    }

    static let enabledDefaultsKey = "cotabbyWordPredictionsEnabled"

    /// On unless the writer turned it off in Settings → Writing.
    static var isEnabledInDefaults: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The production predictor: the bundled n-gram table, dictionary completions from the SymSpell
    /// index the spelling engine already loaded, and the writer's learned phrases. Returns a closure
    /// that predicts nothing if the model file is missing, so a broken bundle only loses the strip.
    static func makePredictor(
        model: NextWordModel?,
        symSpellCorrector: SymSpellCorrector,
        phrases: PersonalPhraseModel,
        languageModel: WordLanguageModelService? = nil
    ) -> (String) -> NextWordPrediction? {
        guard let model else {
            CotabbyLogger.app.error("Next-word model missing from the bundle; word predictions are off.")
            return { _ in nil }
        }
        let hardWords = commonlyMisspelledWords()
        let sources = NextWordPredictor.Sources(
            model: model,
            completions: { symSpellCorrector.completions(of: $0, limit: $1) },
            personal: { phrases.nextWords(after: $0) },
            personalWords: { phrases.words(startingWith: $0) },
            fuzzyCompletions: { symSpellCorrector.fuzzyCompletions(of: $0, limit: $1) },
            isHardToSpell: { hardWords.contains($0) },
            languageModel: { languageModel?.scores(forTextBefore: $0) }
        )
        return { NextWordPredictor.predict(textBefore: $0, sources: sources) }
    }
}
