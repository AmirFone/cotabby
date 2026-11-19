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
///
/// A pick deletes the letters typed so far and types the word, so a pick planned against the wrong
/// text is wrong text in the writer's document. Three rules keep that from happening:
/// - The strip completes the word that ends at the caret. With a letter or digit right after the
///   caret the writer is editing inside a word and there is no strip (`caretIsInsideAWord`); with
///   anything else after it on the line the pick types the word without its space, which the text
///   already there provides.
/// - A pick acts only when the field holds the text the strip was drawn for (`textToReplace`).
///   Accessibility reports a key some time after it was typed (30–400 ms in Chromium and Electron
///   apps), so a read can be older than the strip. `keys` follows the keys themselves, and
///   a re-read that disagrees with it drops the pick instead of counting backspaces against text
///   the field no longer holds.
/// - What is remembered about a text belongs to the field it was read in (`enterField`): Escape, a
///   strip held back, a picked space and the line Return would learn all end with their field.
///
/// The strip is drawn from the keys, not from the field. A host tells Accessibility about a key
/// some time after it was typed, and in the apps this writer lives in (Electron and Chromium) that
/// is often longer than the gap to the next key, so a strip that waited for the field stood a
/// letter or three behind the word, and after a hyphen or a slash still completed the word before
/// it. `predictAhead` therefore predicts for the text every key must leave (`keys.text`) the
/// moment the key is seen, and takes the strip down when that text has nothing to complete. The
/// read of the field that follows confirms it, corrects it, or (most often) finds it already drawn.
@MainActor
final class WordPredictionController: WordPredictionPresenting, InlineCaptureParticipant {
    struct Showing: Equatable {
        let prediction: NextWordPrediction
        var caretRect: CGRect
        var focusChangeSequence: UInt64
        /// Drawn for text the field has not been read to hold: a key was typed since the last read
        /// (the strip may already be the one for that key, see `predictAhead`). A pick reads the
        /// field first.
        var isStale = false
        /// Predicted for the text a pick is about to leave in the field, before the host has
        /// reported that text (see `textToReplace`).
        var followsPick = false
    }

    private struct PendingDecision {
        let keyCode: CGKeyCode
        let consume: Bool
    }

    /// One text field, by the two things that name it. Neither is reliable alone (see
    /// `enterField`).
    private struct Field {
        /// `FocusTracker`'s number for the field. It also moves on when the same field changes
        /// its frame.
        var sequence: UInt64
        /// The Accessibility element's identifier; nil until a snapshot of the field was seen.
        var element: String?
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
    /// True while the spelling bar or the sentence card is on screen: the strip is never drawn
    /// under either, also not from a key (see `predictAhead`).
    private let isAnotherPanelUp: () -> Bool
    /// Takes the strip down when the writer stops typing and keeps it down until the next key.
    private let idle: InlinePanelIdleTimer

    private(set) var showing: Showing?
    /// The slot the writer moved the highlight to with the arrow keys; nil until they do, and again
    /// as soon as the strip shows different words.
    private(set) var arrowedSlot: Int?
    private var pendingDecision: PendingDecision?
    /// Escape hides the strip until the next word starts.
    private var isSuppressed = false
    private var lastLearnedSentence: String?
    /// The last sentence that ended a line Return was pressed on (see `learnSentLine`).
    private var sentSentence: String?
    /// The text before the caret at the last settled keystroke; read when Return sends a line.
    private var lastNotedText = ""
    /// The field the text state here was read in; nil when no supported field has focus. See
    /// `enterField`.
    private var field: Field?
    /// Where the caret stood at the last read of this field: where a strip goes that is drawn from
    /// a key while none is up. A key moves the caret by a letter, and the next read places the
    /// strip exactly.
    private var lastCaretRect: CGRect?
    /// The text before the caret as the keys say it must be by now, and the states it passed
    /// through since the field was last read (`TextFromKeys`). It is never typed from; it is
    /// what a read of the field is held against, to tell a host that has published the writer's
    /// last keys from one that has not, and what the strip is predicted for at each key.
    private var keys = TextFromKeys()
    /// Uptime of the last key seen, for the key-to-strip latency in the debug log.
    private var lastKeyUptimeNanoseconds: UInt64?
    /// Uptime of the last key seen, kept (the one above is used up by the strip it times): how
    /// long ago the writer typed decides whether a field that lacks the last keys is only late.
    private var lastKeyUptimeForLag: UInt64?
    /// The text before the caret that the strip on screen was predicted for. It can be a key ahead
    /// of `lastNotedText` (see `predictAhead`); a redraw must predict for the same text.
    private var shownText = ""
    /// A strip that is ready to draw but waiting for the language model's order (`showOrAwait`).
    private var awaited: (showing: Showing, text: String)?
    private var awaitTimeout: DispatchWorkItem?
    /// The field's text right after a pick typed a word and its space; cleared by the next key.
    private var pickedText: String?
    /// Counts the keys seen. A pick that is waiting for the host (`commit(word:waited:)`) belongs
    /// to the key that asked for it and is dropped when another key follows.
    private var keysSeen: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    var onCaptureStateChanged: (() -> Void)?
    /// Invoked after a picked word has been typed, so the suggestion pipeline re-reads the field.
    var onCommitted: (() -> Void)?
    /// A sentence the writer finished and left standing (it was still in the field, unchanged, after
    /// `learnDelay`, so any fix made to it had already landed), or a chat line sent with Return.
    /// The opt-in training record listens here.
    ///
    /// The second value is the text before the caret when the sentence was finished or sent.
    /// The listener cuts the sentence's context from it. It is handed over, not read by the
    /// listener, because by the time a sentence has settled the field may be empty: a sent
    /// message is cleared at once, and no sentence that ended in a period had any context saved.
    var onSentenceSettled: ((_ sentence: String, _ textBefore: String) -> Void)?
    /// What the strip showed for a word the writer has just finished or picked, and which slot was
    /// taken if any (`StripUseTracker`). The opt-in training record listens here; it is how the
    /// record knows the strip was wrong, or right and ignored, and not only when it was used.
    var onStripUse: ((StripUse) -> Void)?
    private var stripUse = StripUseTracker()

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
        languageModelWait: TimeInterval = 0.05,
        isAnotherPanelUp: @escaping () -> Bool = { false },
        idle: InlinePanelIdleTimer? = nil
    ) {
        self.isAnotherPanelUp = isAnotherPanelUp
        // Built here and not as a default argument: a default is evaluated outside the main actor.
        self.idle = idle ?? InlinePanelIdleTimer()
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
            // A click on a word is the writer being there, like a key.
            self?.idle.noteActivity()
            self?.commit(slot: index)
        }
        idle.whenRunOut { [weak self] in self?.hide(because: "left alone too long") }
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

    func isBehindTheKeys(_ precedingText: String) -> Bool {
        guard let lastKey = lastKeyUptimeForLag else { return false }
        // Only for a moment after the key. A host that still has not shown a key after this long
        // is not going to (the app took the key for something else), and the field is then right
        // and the keys are wrong.
        let sinceKey = DispatchTime.now().uptimeNanoseconds &- lastKey
        return sinceKey < Self.longestHostLagNanoseconds && keys.isEarlierState(precedingText)
    }

    /// The slowest a host is believed to be about a key. Publishing has been measured at up to
    /// 400 ms; three times that leaves room for a busy moment.
    private static let longestHostLagNanoseconds: UInt64 = 1_200_000_000

    func noteTypedText(_ precedingText: String, caretRect: CGRect, focusChangeSequence: UInt64) {
        let read = focusModel.snapshot.context
        enterField(sequence: focusChangeSequence, element: read?.focusChangeSequence == focusChangeSequence ? read?.elementIdentifier : nil)
        // A slow host publishes a burst of keys one state at a time, and any of those states can
        // arrive here as "the text after the key". Taken as that, it put the strip back to a word
        // the writer had already finished (the completions of `r` standing over `read/`), and
        // made the record of this word start over. The strip already shows what the keys left;
        // the read that catches up with them is the one that counts.
        guard !isBehindTheKeys(precedingText) else { return }
        lastNotedText = precedingText
        keys.settle(on: precedingText)
        lastCaretRect = caretRect
        if let use = stripUse.typed(precedingText) { onStripUse?(use) }
        learnFinishedSentence(in: precedingText)
        // `idle.hasRunOut`: this is also called when no key was pressed (screen text became ready,
        // a setting changed), and a strip that went away because the writer stopped must not be
        // put back by that.
        guard isEnabled(), !isSuppressed, !idle.hasRunOut, !caretIsInsideAWord else {
            hide(because: "the strip is off, was dismissed, was left alone, or the caret is inside a word")
            return
        }
        if confirmStripDrawnAhead(for: precedingText, caretRect: caretRect) { return }
        guard let prediction = predict(precedingText) else {
            hide(because: "nothing to predict for this text")
            return
        }
        showOrAwait(Showing(prediction: prediction, caretRect: caretRect, focusChangeSequence: focusChangeSequence), for: precedingText)
    }

    /// The usual case since the strip is drawn from the keys: by the time the field is read, the
    /// strip for exactly this text is already up, or held back for the language model. Then
    /// nothing is predicted or drawn a second time. The strip is only told that the field now
    /// holds its text, so a pick need not read the field again, and where the caret really is.
    private func confirmStripDrawnAhead(for text: String, caretRect: CGRect) -> Bool {
        if awaited?.text == text {
            awaited?.showing.isStale = false
            awaited?.showing.caretRect = caretRect
            return true
        }
        guard awaited == nil, let current = showing, shownText == text else { return false }
        showing?.isStale = false
        if current.caretRect != caretRect {
            showing?.caretRect = caretRect
            redraw()
        }
        return true
    }

    /// What this controller remembers about a text belongs to the field it was read in. When
    /// another field has focus, or none, all of it goes: carried over, an Escape would silence the
    /// first word typed in the next field, a strip held back for the language model would be drawn
    /// over it, the Space after a pick would be swallowed there, and Return there would learn the
    /// old field's line as sent.
    ///
    /// Called from both places a field is named: the focus stream, and `noteTypedText`, in case
    /// text for a new field arrives before that field's snapshot has been delivered here.
    ///
    /// Which field is "another" takes both of a field's names. The sequence number also moves on
    /// when a field only changes its frame, and a message box that grows a line as it fills, or
    /// slides when the page above it reflows, does that in the middle of a sentence; read as a
    /// new field, each such change took the strip down and forgot the text typed so far. The
    /// Accessibility element is the other name: the same element under a new number is the same
    /// field, and everything is kept. (Some hosts hand out a new element for a field that stays
    /// where it is, which is why the number is asked first.) A pick does not rest on this
    /// judgment: it types only into a field that reads back the text the strip was drawn for.
    private func enterField(sequence: UInt64?, element: String?) {
        guard sequence != field?.sequence else {
            if field?.element == nil { field?.element = element }
            return
        }
        if let sequence, let element, element == field?.element {
            field?.sequence = sequence
            showing?.focusChangeSequence = sequence
            awaited?.showing.focusChangeSequence = sequence
            return
        }
        field = sequence.map { Field(sequence: $0, element: element) }
        isSuppressed = false
        pickedText = nil
        lastNotedText = ""
        keys.settle(on: nil)
        lastCaretRect = nil
        hide(because: "focus moved")
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
        // The focus stream only speaks when a snapshot changes, so `enterField` may not have
        // heard of a move yet; the strip was held for one field and is drawn in no other.
        guard !idle.hasRunOut,
              focusModel.snapshot.context?.focusChangeSequence == held.showing.focusChangeSequence else { return }
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
        next.followsPick = current.followsPick
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
        pendingDecision = nil
        arrowedSlot = nil
        guard showing != nil else { return }
        showing = nil
        panel.hide()
        onCaptureStateChanged?()
    }

    // MARK: - Keys

    func observe(_ event: CapturedInputEvent) -> Bool {
        guard !claims(event) else { return true }
        // The key goes on to the app. A strip held back for the language model was predicted for
        // the text before it, so it is stale like one on screen, and the text the field is
        // expected to hold moves on with the key.
        awaited?.showing.isStale = true
        keys.apply { Self.text($0, afterTyping: event) }
        return false
    }

    /// What `text` before the caret becomes when `event` reaches the field, or nil when the key
    /// alone does not tell. Only plain typing is followed: a character, with or without Shift, and
    /// Delete. Escape changes no text. Everything else (an arrow, Return, Tab, a shortcut, input
    /// that composes several characters) may move the caret or edit in a way only the host knows,
    /// and the next settled read has to say what the field holds.
    private static func text(_ text: String, afterTyping event: CapturedInputEvent) -> String? {
        if event.keyCode == KeyCode.escape { return text }
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        guard event.kind == .textMutation, modifiers.isEmpty || modifiers == .shift else { return nil }
        if event.keyCode == KeyCode.delete { return String(text.dropLast()) }
        // One character that a field shows as typed. Return, Tab, forward delete and the function
        // keys also arrive as one "character" (a control code or a private-use one), and what
        // those do to the text is the host's business.
        guard event.characters.count == 1, let scalar = event.characters.unicodeScalars.first,
              event.characters.unicodeScalars.count == 1,
              ![.control, .privateUse, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
        else { return nil }
        return text + event.characters
    }

    /// The strip's own handling of a key: true when it takes the key from the app.
    private func claims(_ event: CapturedInputEvent) -> Bool {
        pendingDecision = nil
        keysSeen &+= 1
        lastKeyUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        lastKeyUptimeForLag = lastKeyUptimeNanoseconds
        if [KeyCode.space, KeyCode.returnKey, KeyCode.keypadEnter].contains(event.keyCode) {
            isSuppressed = false
        }
        // Return on a word the writer arrowed to types that word; it does not send the line.
        // Shift+Return counts too: in a chat box it starts the next line of the same message, and
        // the line it ends is as finished as one that was sent. Only plain Return used to count,
        // which recorded the last line of a message and dropped every line before it.
        if event.keyCode == KeyCode.returnKey, arrowedSlot == nil,
           event.flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl]) {
            learnSentLine()
        }
        let modifiers = ShortcutModifierMask(eventFlags: event.flags)
        if claimPunctuationAfterPick(event, modifiers: modifiers) { return true }
        guard showing != nil else {
            // No strip up (nothing to complete a moment ago, or the writer had stopped): the key
            // may start a word, and the strip for it is drawn now.
            predictAhead(of: event)
            return false
        }
        if modifiers == .option, let slot = KeyCode.digits.firstIndex(of: event.keyCode) {
            return claimWord(inSlot: slot, for: event)
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

    /// Draws the strip for the text this key leaves in the field, from the key itself, without
    /// waiting for the host to publish it to Accessibility (30–400 ms in the apps that are slow
    /// at it, often longer than the gap to the writer's next key).
    ///
    /// Every key is followed, not only the first after a read: `keys.text` is the last read
    /// with each key since applied, so a burst of ten letters is ten exact steps, and it is nil
    /// as soon as one key's effect is not known. Every character is followed, not only letters:
    /// after `-` or `/` the next word is predicted as after a space, and after a period or a
    /// digit there is nothing to complete. When there is nothing to complete, or the text is not
    /// known, the strip comes down. It used to stay as it was, which left the completions of the
    /// word before a hyphen standing over the word after it.
    ///
    /// The strip drawn here is marked stale: a pick reads the field first and acts only if the
    /// field shows this text (`refreshIfStale`). The read that follows the key confirms the strip
    /// (`confirmStripDrawnAhead`) or replaces it.
    private func predictAhead(of event: CapturedInputEvent) {
        guard event.kind == .textMutation, isEnabled(), !isSuppressed else { return }
        // The spelling gate is about to fix this word or put its bar up, and either one hides this
        // strip. Redrawing it here would show for a few milliseconds and be thrown away, and the
        // redraw (a window-server round trip) is main-thread time taken from the fix itself. With
        // the bar or the sentence card still up from the key before, the strip waits for the read
        // that takes that panel down; two panels would stack.
        guard !isSpellingPending(), !isAnotherPanelUp() else { return }
        guard let text = keys.text.flatMap({ Self.text($0, afterTyping: event) }),
              let sequence = field?.sequence, let caretRect = showing?.caretRect ?? lastCaretRect,
              !caretIsInsideAWord, let prediction = predict(text) else {
            hide(because: "the last key left nothing to complete, or what it did is not known yet")
            return
        }
        showOrAwait(Showing(prediction: prediction, caretRect: caretRect, focusChangeSequence: sequence, isStale: true), for: text)
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
    }

    /// Tab or Return on the highlighted word.
    private func claimHighlightedWord(_ event: CapturedInputEvent) -> Bool {
        guard let word = word(inSlot: arrowedSlot ?? 0) else { return false }
        return claim(event) { self.commit(word: word) }
    }

    /// Option+digit on a slot. The key is taken even when the slot is empty, so the chord never
    /// types its own character (`¡`, `™`) while a strip is up. The pick waits for Option to be let
    /// go, and the language model may reorder the strip in that time, so the word in the slot now
    /// is what is carried (see `commit(word:)`).
    private func claimWord(inSlot slot: Int, for event: CapturedInputEvent) -> Bool {
        let word = word(inSlot: slot)
        return claim(event) {
            ModifierRelease.perform {
                guard let word else { return }
                self.commit(word: word)
            }
        }
    }

    private func word(inSlot slot: Int) -> String? {
        guard let words = showing?.prediction.words, words.indices.contains(slot) else { return nil }
        return words[slot]
    }

    /// Types `word` if the strip still offers it. A pick from the keyboard is carried as the word,
    /// not its slot: the strip can show other words by the time the pick runs (keys typed since it
    /// was drawn, or the language model's answer arriving), and a slot number would then type a
    /// word the writer never chose.
    ///
    /// The strip is drawn from the keys, so the writer can press Tab before the host has told
    /// Accessibility about the last letter. The pick then waits for the field to show that letter
    /// (`FieldCheck.behind`) instead of being dropped: Tab was already taken from the app, and a
    /// pick that typed nothing left the writer with a key that did nothing at all. The wait ends
    /// with the first read that shows the text, with any further key, or after `longestWaitForHost`.
    private func commit(word: String, waited: TimeInterval = 0) {
        switch refreshIfStale() {
        case .current:
            guard let slot = showing?.prediction.words.firstIndex(of: word) else { return }
            commit(slot: slot)
        case .behind where waited < Self.longestWaitForHost:
            let key = keysSeen
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hostPollSeconds) { [weak self] in
                guard let self, self.keysSeen == key else { return }
                self.commit(word: word, waited: waited + Self.hostPollSeconds)
            }
        case .behind, .changed:
            hide(because: "the field changed before a pick, or never showed the last keys")
        }
    }

    /// How long a pick waits for a host that has not published the last keys, and how often it
    /// looks. Half a second covers the slowest publish measured (400 ms, the same ceiling the
    /// suggestion pipeline waits for); a host slower than that gets no pick, as before.
    private static let longestWaitForHost: TimeInterval = 0.5
    private static let hostPollSeconds: TimeInterval = 0.02

    /// What a read of the field says about the strip, asked before a pick.
    private enum FieldCheck {
        /// The field holds the text the strip is for.
        case current
        /// The field holds that text without its last few keys: the host has not published them.
        case behind
        /// Another field, other text, or text nobody can vouch for.
        case changed
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
    ///
    /// The re-read is only believed when it shows every key typed since (`keys`). A host
    /// that publishes late still reports the text before those keys; a strip rebuilt from that
    /// would count its backspaces against letters the field has already moved past (`wh` typed, `w`
    /// read back, one backspace takes the `h`: `wwhich`). Then the pick is dropped, and so it is
    /// after a key whose effect is not known. The strip comes back with the next settled read.
    @discardableResult
    private func refreshIfStale() -> FieldCheck {
        guard showing?.isStale == true else { return .current }
        focusModel.refreshNow()
        // `showing` is read again after the refresh: the read can hide the strip (another field)
        // or give its field a new number (`enterField`).
        guard let current = showing, let context = focusModel.snapshot.context,
              context.focusChangeSequence == current.focusChangeSequence else {
            return .changed
        }
        guard keys.holds(context.precedingText) else {
            return keys.isEarlierState(context.precedingText) ? .behind : .changed
        }
        guard let prediction = predict(context.precedingText) else { return .changed }
        show(
            Showing(prediction: prediction, caretRect: context.caretRect, focusChangeSequence: current.focusChangeSequence),
            for: context.precedingText
        )
        return .current
    }

    // MARK: - Commit

    private func commit(slot: Int) {
        guard refreshIfStale() == .current else {
            hide(because: "the field changed before a pick, or does not show the last keys yet")
            return
        }
        guard let current = showing, current.prediction.words.indices.contains(slot) else { return }
        let word = current.prediction.words[slot]
        let prefix = current.prediction.prefix
        guard let precedingText = textToReplace(under: current), precedingText.hasSuffix(prefix) else {
            hide(because: "the field does not hold the text the strip was drawn for")
            return
        }
        guard !caretIsInsideAWord else {
            hide(because: "the caret is inside a word")
            return
        }
        // With text already after the caret on its line, the pick types the word alone: that text
        // starts with the space or the mark that follows the word (`I want| to go` must not become
        // `I wanted  to go`).
        let addsSpace = caretEndsItsLine
        let typed = addsSpace ? word + " " : word
        // Backspace keys, counted on the letters as the field holds them (`BackspaceKeyCount`): for
        // letters with a decomposed accent the number depends on the host, and then nothing is typed.
        guard let backspaces = BackspaceKeyCount.deleting(precedingText.suffix(prefix.count)) else {
            hide(because: "the letters typed cannot be deleted with a known number of keys")
            return
        }
        let inserted = prefix.isEmpty
            ? inserter.insert(typed)
            : inserter.replace(deletingUTF16Count: backspaces, with: typed)
        guard inserted else {
            hide(because: "the pick could not be typed")
            return
        }
        onStripUse?(stripUse.picked(slot: slot, word: word, shown: current.prediction.words, textBefore: precedingText))
        // Predict the following word from the text the field is about to hold, so the next pick is
        // available before the host has even published this one.
        let stem = String(precedingText.dropLast(prefix.count))
        let expected = stem + typed
        // The states the field passes through while the pick's own keys land: the letters typed
        // go, a letter at a time, then the word comes, a letter at a time. A read of any of them
        // is the host on its way, not other text.
        let going = (1...max(prefix.count, 1)).map { String(precedingText.dropLast(min($0, prefix.count))) }
        let coming = typed.indices.dropFirst().map { stem + typed[..<$0] }
        keys.jump(to: expected, through: going + coming)
        // Only a pick that typed a space leaves one for the next key to fight with, and only then
        // does a next word start at the caret.
        pickedText = addsSpace ? expected : nil
        if addsSpace, let next = predict(expected) {
            var following = Showing(prediction: next, caretRect: current.caretRect, focusChangeSequence: current.focusChangeSequence)
            following.followsPick = true
            show(following, for: expected)
        } else {
            hide(because: addsSpace ? "nothing to predict after the pick" : "the pick joined text that was already there")
        }
        focusModel.invalidateTransientCaretCaches()
        onCommitted?()
    }

    /// The text before the caret that a pick may delete from and type after, or nil when the field
    /// is not known to hold what the strip was drawn for. A pick types blind (backspaces, then the
    /// word), so the letters it deletes must be the ones the strip showed a completion for.
    ///
    /// Normally that means the field reads back as `shownText`. If it does not, the caret was put
    /// elsewhere, the host changed the text, or another field has focus, and there is no pick.
    ///
    /// The one exception is a pick right after a pick (Tab, Tab). The strip is then already ahead
    /// of the host: it was predicted for the text the first pick leaves, which the host reports
    /// some time later. A field that still reads as an earlier part of that text is only behind
    /// Cotabby's own keys, and the next word is planned from `shownText`. That is safe because such
    /// a strip follows a space: nothing is deleted, the word is typed after keys already on their
    /// way. Planning from the lagging read instead would lose the first pick from the text the
    /// next strip and the punctuation fix are worked out from.
    private func textToReplace(under current: Showing) -> String? {
        guard let context = focusModel.snapshot.context, !context.isSecure,
              context.focusChangeSequence == current.focusChangeSequence else { return nil }
        if TextFromKeys.isSameText(context.precedingText, shownText) { return context.precedingText }
        let isBehindOwnPick = current.followsPick && current.prediction.prefix.isEmpty
            && shownText.hasPrefix(context.precedingText)
        return isBehindOwnPick ? shownText : nil
    }

    /// A letter or digit right after the caret: the writer is editing inside a word, or directly
    /// in front of one. The strip only knows the letters before the caret, so a pick here would
    /// complete the left half and leave the rest standing (`Please wr|old` → `Please wrong old`).
    /// An apostrophe counts when a letter follows it (`don|'t`), not as a closing quote.
    private var caretIsInsideAWord: Bool {
        guard let trailing = focusModel.snapshot.context?.trailingText, let next = trailing.first else { return false }
        if next.isLetter || next.isNumber { return true }
        return (next == "'" || next == "’") && trailing.dropFirst().first?.isLetter == true
    }

    static let closingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    /// Another panel (the spelling bar) typed a word and its space; treat the next key like one after
    /// a strip pick.
    func notePickAddedSpace(expectedText: String) {
        guard !expectedText.isEmpty else { return }
        pickedText = expectedText
        // That panel took the key that picked, so `observe` never saw it; the field has moved on
        // from the last settled read all the same.
        keys.jump(to: expectedText)
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
        // The mark is typed by `movePickSpace`, a moment from now and in one of two ways, so what
        // the field holds is not known until it is read again; the strip on screen was predicted
        // for the text before the mark.
        showing?.isStale = true
        keys.settle(on: nil)
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
        // Every closing mark goes, not one: `No way!!!` left `No way!!` as the body, whose own
        // last mark then read as the end of the sentence before, and nothing was learned.
        let body = trimmed.dropLast(trimmed.reversed().prefix { ".!?".contains($0) }.count)
        let start = Self.sentenceStart(in: body)
        let sentence = body[start...].trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty, sentence != lastLearnedSentence else { return }
        lastLearnedSentence = sentence
        // The sentence as the sentence pass sees it (punctuation kept, abbreviation-aware), so a
        // listener can match it against that pass's fixes. Nil for text the pass leaves alone.
        let finished = FinishedSentenceExtractor.extract(from: text)?.sentence
        settleAfterDelay(sentence, finished: finished, textBefore: text)
    }

    /// Learns `sentence` once `learnDelay` has passed, if it is still in the field as written or
    /// was sent in the meantime. Sending clears the field, which is not the writer taking the
    /// sentence back; without that exception a line sent within the delay was never learned.
    private func settleAfterDelay(_ sentence: String, finished: String?, textBefore: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + learnDelay) { [weak self] in
            guard let self else { return }
            let isStillThere = self.focusModel.snapshot.context?.precedingText.contains(sentence) == true
            guard isStillThere || self.sentSentence == sentence else { return }
            self.learn(sentence)
            if let finished { self.onSentenceSettled?(finished, textBefore) }
        }
    }

    /// Return ends the line being written. A chat line usually has no period, so it would never
    /// count as finished; it is learned at once because the field is often cleared on send. A line
    /// that does end in a period waits out `learnDelay` like any finished sentence (in an editor
    /// Return only starts a new line, and the sentence pass may still fix it), but is remembered as
    /// sent so that the field being cleared does not lose it.
    ///
    /// The line is `lastNotedText`, a read that can be a few keys old: most messages end with a
    /// word followed at once by Return, and a host that publishes late (Slack, Chrome) has not
    /// reported those last letters yet. It is learned all the same. Sent chat lines are the main
    /// thing the strip learns from, and the learner vouches for each word on its own
    /// (`PersonalPhraseModel.Vouching`), so a last word cut short (`jo` for `job`) is not counted
    /// while the rest of the line is. A line typed in another field is never learned here:
    /// `enterField` empties `lastNotedText` when focus moves.
    private func learnSentLine() {
        // The text as the keys left it when there is one: it has the last letters, which a host
        // that publishes late has not reported when Return follows the word at once. Read from the
        // field alone, one line in ten was saved with its last word cut short.
        let text = keys.text ?? lastNotedText
        let line = (text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let closingMarks = line.reversed().prefix { ".!?".contains($0) }.count
        let body = line.dropLast(closingMarks)
        let start = Self.sentenceStart(in: body)
        let sentence = body[start...].trimmingCharacters(in: .whitespaces)
        guard sentence.split(separator: " ").count >= 3 else { return }
        if closingMarks > 0 { sentSentence = sentence }
        guard sentence != lastLearnedSentence else { return }
        lastLearnedSentence = sentence
        guard closingMarks > 0 else {
            learn(sentence)
            onSentenceSettled?(sentence, text)
            return
        }
        let asWritten = line[start...].trimmingCharacters(in: .whitespaces)
        settleAfterDelay(
            sentence, finished: FinishedSentenceExtractor.extract(from: text + " ")?.sentence ?? asWritten, textBefore: text
        )
    }

    /// Where the last sentence of `body` begins: after the last closing mark that ends one, or at
    /// the start. A mark ends a sentence only when white space follows it; the dot in a file
    /// name, a version or a web address ends nothing, and read as an end it made the saved
    /// "sentence" begin in the middle of `report.txt`.
    private static func sentenceStart(in body: Substring) -> Substring.Index {
        var index = body.endIndex
        while index > body.startIndex {
            let previous = body.index(before: index)
            if body[previous].isNewline { return index }
            if ".!?".contains(body[previous]), index < body.endIndex, body[index].isWhitespace { return index }
            index = previous
        }
        return body.startIndex
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
        if let use = stripUse.shown(next.prediction.words, for: text) { onStripUse?(use) }
        if next.prediction.words != showing?.prediction.words {
            arrowedSlot = nil
        }
        showing = next
        redraw()
        // For the on-screen suite, whose key checks need the words that are on the strip: since the
        // strip learns the writer, a tool without that history no longer predicts them. Trace
        // level, so the line is only built under `-cotabby-debug`.
        CotabbyLogger.suggestion.trace("Word strip words: \(next.prediction.words.joined(separator: " · "))")
        if let keyTime = lastKeyUptimeNanoseconds {
            lastKeyUptimeNanoseconds = nil
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - keyTime) / 1_000_000
            CotabbyLogger.suggestion.debug("Word strip shown \(String(format: "%.1f", elapsed)) ms after the key")
        }
        if !wasCapturing {
            onCaptureStateChanged?()
        }
    }

    private func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        // Before anything that depends on a strip being up: Escape, a held-back strip and the
        // noted line outlive the strip, and must still end with their field. A secure field counts
        // as no field. The snapshot handed in is used, not `focusModel.snapshot`: a `@Published`
        // property tells its subscribers before it changes.
        let readable = snapshot.context.flatMap { $0.isSecure ? nil : $0 }
        enterField(sequence: readable?.focusChangeSequence, element: readable?.elementIdentifier)
        guard let current = showing else { return }
        guard let context = readable, context.focusChangeSequence == current.focusChangeSequence else {
            isSuppressed = false
            hide(because: "focus moved")
            return
        }
        guard context.caretRect != current.caretRect else { return }
        showing?.caretRect = context.caretRect
        redraw()
    }
}

extension WordPredictionController {
    /// The bundled list of words with many recorded misspellings (`commonly_misspelled_en.txt`).
    static func commonlyMisspelledWords(in bundle: Bundle = .main) -> Set<String> {
        guard let url = bundle.url(forResource: "commonly_misspelled_en", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(contents.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
    }

    /// The words of `prediction_words_en.txt`: everyday words the spelling dictionary and the
    /// n-gram table lack, which the language model can still offer.
    static func supplementWords(in bundle: Bundle = .main) -> Set<String> {
        let urls = [bundle.url(forResource: "prediction_words_en", withExtension: "txt"), TechnicalVocabulary.stripListURL(in: bundle)]
        return Set(WordLanguageModelCore.entries(in: urls.compactMap { $0 }).map(\.word))
    }

    /// The usual capitals of the bundled software terms (`github` → `GitHub`), empty when that
    /// vocabulary is off.
    static func technicalCapitals(in bundle: Bundle = .main) -> [String: String] {
        guard let url = TechnicalVocabulary.stripListURL(in: bundle),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return TechnicalVocabulary.capitals(inStripList: contents)
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
        vocabulary: PersonalVocabulary? = nil,
        languageModel: WordLanguageModelService? = nil,
        americanSpellings: AmericanSpellings? = nil
    ) -> (String) -> NextWordPrediction? {
        guard let model else {
            CotabbyLogger.app.error("Next-word model missing from the bundle; word predictions are off.")
            return { _ in nil }
        }
        let hardWords = commonlyMisspelledWords()
        let supplement = supplementWords()
        let capitals = technicalCapitals()
        var sources = NextWordPredictor.Sources(
            model: model,
            completions: { symSpellCorrector.completions(of: $0, limit: $1) },
            personal: { phrases.nextWords(after: $0) },
            personalWords: { phrases.words(startingWith: $0) },
            fuzzyCompletions: { symSpellCorrector.fuzzyCompletions(of: $0, limit: $1) },
            nearMisses: { symSpellCorrector.nearMissCompletions(of: $0, limit: $1) },
            isHardToSpell: { hardWords.contains($0) },
            languageModel: { languageModel?.scores(forTextBefore: $0) },
            isKnownWord: { supplement.contains($0) },
            americanSpellings: americanSpellings
        )
        // The writer's own terms are counted in lowercase (`PersonalPhraseModel.Vouching`); their
        // vocabulary remembers how they write them (`Kubernetes`).
        sources.usualCapitals = { capitals[$0] ?? vocabulary?.preferredCasing(of: $0) }
        sources.personalTotal = { phrases.totalWords }
        sources.personalSpread = { phrases.spread(of: $0) }
        sources.generalCount = { symSpellCorrector.count(of: $0) }
        return { NextWordPredictor.predict(textBefore: $0, sources: sources) }
    }
}
