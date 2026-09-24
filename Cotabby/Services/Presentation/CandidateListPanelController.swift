import AppKit
import SwiftUI

/// File overview:
/// AppKit shell for the candidate list and the brief auto-fix confirmation pill. It borrows the emoji
/// picker's window recipe (borderless, non-activating, never key, floats over full-screen apps) so the
/// writer keeps typing in their own app while the list is up. All navigation state lives in
/// `CandidateListController`; this class only sizes, positions, and hides the panel.
@MainActor
final class CandidateListPanelController: CandidateListPanelPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?

    /// Long enough to read "teh → the", short enough to be gone before the next word is typed.
    private static let flashDurationSeconds: TimeInterval = 1.1
    /// A sentence takes longer to read than one word.
    private static let sentenceFlashDurationSeconds: TimeInterval = 1.8

    private let model = CandidateListViewModel()
    private var isVisible = false
    private var monitorsInstalled = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var flashHideWorkItem: DispatchWorkItem?

    private lazy var panel: CandidateListPanel = {
        let panel = CandidateListPanel(
            contentRect: CGRect(x: 0, y: 0, width: 160, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }()

    private lazy var hostingView: CandidateListHostingView = {
        CandidateListHostingView(rootView: CandidateListView(model: model) { [weak self] index in
            self?.onSelectIndex?(index)
        })
    }()

    func show(offer: CandidateOffer, selectedIndex: Int, acceptKeyLabel: String) {
        flashHideWorkItem?.cancel()
        let rows = offer.candidates.enumerated().map { index, text in
            CandidateListViewModel.Row(
                text: text,
                confidence: offer.scores.indices.contains(index) ? offer.scores[index] : nil
            )
        }
        model.content = offer.isSpellingBar
            ? .bar(rows: rows, isContextRefined: offer.isContextRefined)
            : .choices(header: Self.header(for: offer), rows: rows)
        model.selectedIndex = selectedIndex
        model.acceptKeyLabel = acceptKeyLabel
        panel.ignoresMouseEvents = false
        place(near: offer.caretRect)
        installClickMonitorsIfNeeded()
    }

    func setSelectedIndex(_ index: Int) {
        model.selectedIndex = index
    }

    func showFlash(typo: String, correction: String, caretRect: CGRect) {
        model.content = .flash(typo: typo, correction: correction)
        panel.ignoresMouseEvents = true
        removeClickMonitors()
        place(near: caretRect)
        let hide = DispatchWorkItem { [weak self] in self?.hide() }
        flashHideWorkItem?.cancel()
        flashHideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDurationSeconds, execute: hide)
    }

    func showSentenceFlash(segments: [SentenceFixSegment], caretRect: CGRect) {
        model.content = .sentenceFix(segments)
        model.acceptKeyLabel = ""
        panel.ignoresMouseEvents = true
        removeClickMonitors()
        place(near: caretRect)
        let hide = DispatchWorkItem { [weak self] in self?.hide() }
        flashHideWorkItem?.cancel()
        flashHideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sentenceFlashDurationSeconds, execute: hide)
    }

    func showSentenceReview(_ review: SentenceReviewPresentation, caretRect: CGRect, acceptKeyLabel: String) {
        flashHideWorkItem?.cancel()
        model.content = .review(review)
        model.selectedIndex = review.selectedIndex
        model.acceptKeyLabel = acceptKeyLabel
        panel.ignoresMouseEvents = false
        place(near: caretRect)
        installClickMonitorsIfNeeded()
    }

    func showSentenceFix(segments: [SentenceFixSegment], caretRect: CGRect, acceptKeyLabel: String) {
        flashHideWorkItem?.cancel()
        model.content = .sentenceFix(segments)
        model.acceptKeyLabel = acceptKeyLabel
        panel.ignoresMouseEvents = false
        place(near: caretRect)
        installClickMonitorsIfNeeded()
    }

    func hide() {
        flashHideWorkItem?.cancel()
        flashHideWorkItem = nil
        removeClickMonitors()
        guard isVisible else { return }
        isVisible = false
        panel.orderOut(nil)
    }

    private static func header(for offer: CandidateOffer) -> String? {
        switch offer.source {
        case .spelling(let typo): return typo
        case .continuation: return nil
        }
    }

    private func place(near caretRect: CGRect) {
        if panel.contentView !== hostingView {
            panel.contentView = hostingView
        }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let frame = CandidateListPanelLayout.frame(
            caretRect: caretRect,
            contentSize: size,
            visibleFrame: visibleFrame(for: caretRect)
        )
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    private func visibleFrame(for caretRect: CGRect) -> CGRect {
        let midpoint = CGPoint(x: caretRect.midX, y: caretRect.midY)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    }

    private func installClickMonitorsIfNeeded() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.onClickOutside?()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                self.onClickOutside?()
            }
            return event
        }
    }

    private func removeClickMonitors() {
        monitorsInstalled = false
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }
}

/// The panel never becomes key, so without this the first click on a slot would only try (and fail)
/// to activate the window instead of reaching the SwiftUI tap handler. Deliberately not generic: the
/// Swift 6.3 optimizer crashes on the synthesized deinit of a generic `NSHostingView` subclass.
private final class CandidateListHostingView: NSHostingView<CandidateListView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Clicking a row must never take keyboard focus from the app the writer is typing in.
private final class CandidateListPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Places the list just above the line being typed (so it never covers the ghost text to the right
/// of the caret or the next lines), dropping below the caret only when there is no room above.
enum CandidateListPanelLayout {
    static let caretGap: CGFloat = 6

    static func frame(caretRect: CGRect, contentSize: CGSize, visibleFrame: CGRect) -> CGRect {
        var originX = caretRect.minX - 12
        if originX + contentSize.width > visibleFrame.maxX {
            originX = visibleFrame.maxX - contentSize.width
        }
        originX = max(originX, visibleFrame.minX)

        let aboveOriginY = caretRect.maxY + caretGap
        let belowOriginY = caretRect.minY - caretGap - contentSize.height
        let originY = aboveOriginY + contentSize.height <= visibleFrame.maxY
            ? aboveOriginY
            : max(belowOriginY, visibleFrame.minY)
        return CGRect(x: originX, y: originY, width: contentSize.width, height: contentSize.height)
    }
}
