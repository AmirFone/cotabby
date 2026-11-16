import AppKit

/// File overview:
/// Says "off" or "on" for a moment when the toggle shortcut is pressed.
///
/// Why it exists: the shortcut is pressed mid-sentence with the eyes on the text, and the only other
/// sign that it worked is a small icon change in the menu bar. Without an answer at the caret the
/// writer presses it twice and ends up where they started.
///
/// It reuses the sentence flash of `CandidateListPanelPresenting` (a short line of text on the same
/// glass panel that confirms a fix, not clickable, gone in under two seconds) through a panel of its
/// own, so a notice never replaces or is replaced by a spelling bar. Owned by `CotabbyAppEnvironment`
/// for the life of the app and called from the toggle shortcut only: a switch flipped in the menu or
/// in Settings already shows its new state where the writer is looking.
@MainActor
final class ToggleNoticeController {
    private let panel: CandidateListPanelPresenting
    private let caretRect: () -> CGRect?
    private let pointerLocation: () -> CGPoint

    /// - Parameters:
    ///   - caretRect: the caret of the focused text field in screen coordinates, nil when no
    ///     supported field has focus.
    ///   - pointerLocation: where the notice goes instead, for a shortcut pressed with no text
    ///     field in focus (or in an app whose caret Cotabby cannot read).
    init(
        panel: CandidateListPanelPresenting,
        caretRect: @escaping () -> CGRect?,
        pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.panel = panel
        self.caretRect = caretRect
        self.pointerLocation = pointerLocation
    }

    func show(isOn: Bool, shortcutLabel: String) {
        let anchor = caretRect() ?? CGRect(origin: pointerLocation(), size: .zero)
        let message = Self.message(isOn: isOn, shortcutLabel: shortcutLabel)
        panel.showSentenceFlash(segments: [SentenceFixSegment(text: message, isChanged: false)], caretRect: anchor)
    }

    /// The off notice names the way back, because that is the moment the writer needs it.
    nonisolated static func message(isOn: Bool, shortcutLabel: String) -> String {
        isOn ? "Cotabby is on" : "Cotabby is off. \(shortcutLabel) turns it back on."
    }
}
