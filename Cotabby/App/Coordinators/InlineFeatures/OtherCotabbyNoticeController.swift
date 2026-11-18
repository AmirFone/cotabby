import AppKit
import Combine
import Logging

/// File overview:
/// Says so, once, when the released Cotabby app is running next to this build.
///
/// Why it matters: the two are separate apps with separate settings, and each watches the keyboard.
/// The released one draws its own ghost text and takes Tab for it, so with both running a Tab meant
/// for this build's word strip also types the other's guess, and words appear that nobody chose.
/// Nothing in this build can stop another app doing that; what it can do is tell the writer, at the
/// caret, the first time they start typing while the other one is up. Without the notice the only
/// symptom is "it sometimes types the wrong word", which looks like this build's fault.
///
/// The notice is the same short line on the glass panel that the toggle shortcut uses, through a
/// panel of its own. It is shown once per launch of either app: once at the first text field focused
/// while the other app is running, and again only if the other app is started later. Owned by
/// `CotabbyAppEnvironment` for the life of the app.
@MainActor
final class OtherCotabbyNoticeController {
    /// The released app's bundle identifier; this build's has a suffix, which is how the two can be
    /// installed side by side at all.
    nonisolated static let releasedBundleIdentifier = "com.jacobfu.tabby"

    private let panel: CandidateListPanelPresenting
    private let isOtherRunning: () -> Bool
    private let ownBundleIdentifier: String?
    private var hasShown = false
    private var launchObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    init(
        panel: CandidateListPanelPresenting,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isOtherRunning: @escaping () -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: OtherCotabbyNoticeController.releasedBundleIdentifier).isEmpty
        }
    ) {
        self.panel = panel
        self.ownBundleIdentifier = ownBundleIdentifier
        self.isOtherRunning = isOtherRunning
    }

    nonisolated deinit {}

    /// Starts watching: every focus change is a chance to show the notice where the writer is
    /// looking, and the other app being started later makes the notice due again.
    func start(focus: AnyPublisher<FocusSnapshot, Never>) {
        focus
            .sink { [weak self] snapshot in
                guard let caret = snapshot.context?.caretRect else { return }
                self?.noteTextFieldFocus(caretRect: caret)
            }
            .store(in: &cancellables)
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let launched = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard launched == Self.releasedBundleIdentifier else { return }
            MainActor.assumeIsolated { self?.hasShown = false }
        }
    }

    /// A text field Cotabby works in has focus, with its caret at `caretRect`.
    func noteTextFieldFocus(caretRect: CGRect) {
        guard Self.isNoticeDue(
            ownBundleIdentifier: ownBundleIdentifier, hasShown: hasShown, isOtherRunning: isOtherRunning
        ) else { return }
        hasShown = true
        CotabbyLogger.app.warning("The released Cotabby app is also running; its ghost text will take Tab alongside this build.")
        panel.showSentenceFlash(segments: [SentenceFixSegment(text: Self.message, isChanged: false)], caretRect: caretRect)
    }

    /// The notice is due when this is not the released app itself, it has not been shown since the
    /// other app was last started, and the other app is running. The running check is asked last
    /// and only when the rest holds: it lists every running app, and focus changes are frequent.
    nonisolated static func isNoticeDue(ownBundleIdentifier: String?, hasShown: Bool, isOtherRunning: () -> Bool) -> Bool {
        ownBundleIdentifier != releasedBundleIdentifier && !hasShown && isOtherRunning()
    }

    nonisolated static let message = "The released Cotabby is running too and will also answer Tab. Quit it to use this one alone."
}
