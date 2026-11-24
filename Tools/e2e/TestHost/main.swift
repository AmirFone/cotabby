import AppKit

/// A plain text view (plus a one-line field for Tab-focus checks) for Cotabby's live end-to-end tests. It exists so the tests never touch
/// the writer's own apps, documents, or macOS settings: nothing is saved, and macOS's own
/// autocorrect, capitalization, and substitutions are switched off on this view only, so the tests
/// measure Cotabby alone.
///
/// The test script talks to it through three files in the same cache folder, so it needs no
/// Accessibility grant of its own: `doc.txt` and `field.txt` mirror the two texts (rewritten within
/// 30 ms of any change, whoever made it), and each line appended to `host-commands.txt` is one of
/// `focus-text`, `focus-field`, `clear-field`, `light`, `dark`, `busy`, `tear-read`, `late <ms>`,
/// `slow <ms>`, `stall <ms> <every ms>`, `nudge-frame`.
final class HostDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var textView: NSTextView!
    private var field: NSTextField!
    private var mirrored: (doc: String?, field: String?) = (nil, nil)
    private var commandOffset: UInt64 = 0
    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CotabbyE2E", isDirectory: true)

    private func tick() {
        if textView.string != mirrored.doc {
            mirrored.doc = textView.string
            try? textView.string.write(to: folder.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)
        }
        if field.stringValue != mirrored.field {
            mirrored.field = field.stringValue
            try? field.stringValue.write(to: folder.appendingPathComponent("field.txt"), atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent("host-commands.txt")) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: commandOffset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        commandOffset += UInt64(data.count)
        for command in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            switch command {
            case "focus-text": window.makeFirstResponder(textView)
            case "focus-field": window.makeFirstResponder(field)
            case "clear-field": field.stringValue = ""
            // A light or dark window regardless of the system setting, so a panel floating over it can
            // be checked against both a white and a black page.
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "busy": showBusyBackdrop()
            // The next read of the text view's selection is answered as from before a Backspace
            // (see `TearingTextView`).
            case "tear-read": TearingTextView.tornSelectionReads = 1
            // The window grows a little and moves, as a message box does when it takes another
            // line: the same text view with another frame.
            case "nudge-frame":
                var frame = window.frame
                frame.size.height += 18
                frame.origin.x += 6
                window.setFrame(frame, display: true)
            // `late 300`: Accessibility reads of the text view answer with the text as it was
            // 300 ms ago, like an app that is slow to publish a key; `late 0` ends it.
            case let line where line.hasPrefix("late "):
                TearingTextView.publishDelay = (Double(line.dropFirst(5)) ?? 0) / 1000
                TearingTextView.noteText(of: textView)
            // `slow 8`: every Accessibility read of the text view takes 8 ms to answer, like an
            // app whose main thread is busy; `slow 0` ends it.
            case let line where line.hasPrefix("slow "):
                TearingTextView.readDelay = (Double(line.dropFirst(5)) ?? 0) / 1000
            // `stall 90 400`: once every 400 ms one Accessibility read takes 90 ms to answer,
            // longer than Cotabby waits for it (50 ms), like an app that is busy for a moment
            // now and then; `stall 0 0` ends it.
            case let line where line.hasPrefix("stall "):
                let parts = line.dropFirst(6).split(separator: " ").compactMap { Double($0) }
                TearingTextView.stallDelay = (parts.first ?? 0) / 1000
                TearingTextView.stallPeriod = (parts.dropFirst().first ?? 0) / 1000
            default: break
            }
        }
    }

    /// Every change of the text or the caret goes into the view's record of what it held when
    /// (see `TearingTextView.publishDelay`).
    @objc private func textOrCaretChanged(_ notification: Notification) {
        TearingTextView.noteText(of: textView)
    }

    /// Fills the whole window, title bar included, with a loud pattern, for judging how see-through
    /// a panel floating over it is. A white or black page cannot show that: a clear panel and an
    /// opaque one look the same over a flat color.
    ///
    /// The pattern is the window's background color rather than a view, because the title bar draws
    /// that color too once it is made transparent, and a panel above the first text line sits partly
    /// over the title bar. The text view, its scroll view and the field stop painting their own
    /// backgrounds so the pattern shows through them; their frames do not change, so the caret (and
    /// with it the panel) stays exactly where it is in the plain looks.
    private func showBusyBackdrop() {
        NSApp.appearance = NSAppearance(named: .aqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(patternImage: Self.busyPattern(size: window.frame.size))
        textView.drawsBackground = false
        textView.enclosingScrollView?.drawsBackground = false
        field.drawsBackground = false
        field.isBezeled = false
    }

    /// Hard-edged shapes in saturated colors plus black and white lettering: blur shows up as soft
    /// edges, refraction as bent ones, and an opaque tint as washed-out color. The lettering runs
    /// along the top strip, which is where the panel lands.
    private static func busyPattern(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let hues: [CGFloat] = [0.0, 0.08, 0.15, 0.33, 0.5, 0.6, 0.75, 0.9]
            let stripe: CGFloat = 34
            var index = 0
            var x = -rect.height
            while x < rect.width {
                NSColor(hue: hues[index % hues.count], saturation: 0.95, brightness: 1, alpha: 1).setFill()
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x, y: 0))
                path.line(to: NSPoint(x: x + stripe, y: 0))
                path.line(to: NSPoint(x: x + stripe + rect.height, y: rect.height))
                path.line(to: NSPoint(x: x + rect.height, y: rect.height))
                path.close()
                path.fill()
                x += stripe
                index += 1
            }
            for (offset, color) in [NSColor.white, .black, .systemYellow, .systemPink, .black, .white].enumerated() {
                color.setFill()
                let center = NSPoint(x: 90 + CGFloat(offset) * 120, y: rect.height - 62)
                NSBezierPath(ovalIn: NSRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)).fill()
            }
            let line = "GLASS 0123456789 the quick brown fox jumps over the lazy dog GLASS 0123456789"
            for (row, color) in [NSColor.black, .white].enumerated() {
                NSAttributedString(
                    string: line,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: color]
                ).draw(at: NSPoint(x: 12, y: rect.height - 52 - CGFloat(row) * 22))
            }
            return true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 240, y: 360, width: 760, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cotabby E2E Host"
        // macOS's own inline prediction is off for this app only (the setting is written to the test
        // host's preferences), like the other typing help below, so that every character in the two
        // texts was typed by the test or by Cotabby.
        UserDefaults.standard.set(false, forKey: "NSAutomaticInlinePredictionEnabled")
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        // The view keeps everything `scrollableTextView()` set up and only answers two Accessibility
        // questions differently on request. Changing the class of a live object is sound here
        // because the subclass adds no stored properties of its own.
        object_setClass(text, TearingTextView.self)
        text.font = .systemFont(ofSize: 15)
        text.isAutomaticSpellingCorrectionEnabled = false
        text.allowsUndo = true
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isGrammarCheckingEnabled = false
        text.setAccessibilityIdentifier("e2e-text")
        // A one-line field above the text view, for checks where Tab must keep moving focus.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 320))
        let field = NSTextField(frame: NSRect(x: 8, y: 288, width: 744, height: 24))
        field.autoresizingMask = [.width, .minYMargin]
        field.setAccessibilityIdentifier("e2e-field")
        field.isAutomaticTextCompletionEnabled = false
        text.inlinePredictionType = .no
        scroll.frame = NSRect(x: 0, y: 0, width: 760, height: 280)
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(field)
        container.addSubview(scroll)
        field.nextKeyView = text
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
        textView = text
        self.field = field
        NotificationCenter.default.addObserver(
            self, selector: #selector(textOrCaretChanged), name: NSText.didChangeNotification, object: text
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(textOrCaretChanged), name: NSTextView.didChangeSelectionNotification, object: text
        )
        let commands = folder.appendingPathComponent("host-commands.txt")
        try? Data().write(to: commands)
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The test text view, able to answer once as a field does when a Backspace lands in the middle of
/// Cotabby's read of it: the selection and the character count are from before the key (a caret
/// past the end of the text as it is now), the text itself from after it. Cotabby then cannot fetch
/// the text around that caret, falls back to the whole value, and finds the selection outside it.
/// On a real field this is a race that shows up once in a few hundred Backspaces, too rarely to
/// test by waiting for it; `tear-read` makes the next read one of those.
///
/// It can also answer late. A native text view tells Accessibility about a key within a few
/// milliseconds; Electron and Chromium apps (the chat and browser windows most writing happens in)
/// take 30 to 400 ms, often longer than the gap to the next key. With `publishDelay` set, every
/// Accessibility read of the text and the caret is answered with what the view held that long ago,
/// while the view itself, and `doc.txt`, are up to date. That is the one condition under which a
/// strip that waits for the field falls behind the writer, and no native view shows it.
///
/// And it can answer slowly. Accessibility reads are answered on the app's main thread, and a
/// client waits for each one. A chat app that is drawing a long reply takes 5 to 40 ms per read
/// where a native view takes a fraction of one, and Cotabby makes several reads per key on its own
/// main thread, the thread its key taps are served on. With `readDelay` set, each read here
/// waits that long before it answers. Keys then queue up in Cotabby while it waits, which is the
/// condition under which a key reached its two taps in the wrong order.
///
/// The state is static because the view is made by `NSTextView.scrollableTextView()` and only given
/// this class afterwards, so it can hold nothing of its own.
final class TearingTextView: NSTextView {
    static var tornSelectionReads = 0
    private static var countIsFromBeforeTheKey = false
    private static let charactersDeleted = 4

    /// How far behind Accessibility reads are answered, in seconds; 0 answers with the live text.
    static var publishDelay: TimeInterval = 0
    /// What the view held and when, oldest first; only kept while `publishDelay` is set.
    private static var held: [(time: TimeInterval, text: String, selection: NSRange)] = []

    /// How long each Accessibility read takes to answer, in seconds; 0 answers at once.
    static var readDelay: TimeInterval = 0
    /// One read in every `stallPeriod` seconds takes `stallDelay` seconds to answer. A client
    /// that gives a read less time than that gets no answer at all for it, which is not the
    /// same as a slow answer: it cannot tell a busy app from a field that is gone.
    static var stallDelay: TimeInterval = 0
    static var stallPeriod: TimeInterval = 0
    private static var nextStall: TimeInterval = 0
    private static func dawdle() {
        let now = ProcessInfo.processInfo.systemUptime
        if stallDelay > 0, now >= nextStall {
            nextStall = now + stallPeriod
            Thread.sleep(forTimeInterval: stallDelay)
            return
        }
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
    }

    static func noteText(of view: NSTextView) {
        guard publishDelay > 0 else {
            held = []
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        held.append((now, view.string, view.selectedRange()))
        // Everything older than the entry that is being published now can go.
        while held.count > 1, held[1].time <= now - publishDelay { held.removeFirst() }
    }

    /// The text and caret an Accessibility client is told about right now: the newest that is at
    /// least `publishDelay` old. Nil when reads are answered live.
    private static var published: (text: String, selection: NSRange)? {
        guard publishDelay > 0, let oldest = held.first else { return nil }
        let due = ProcessInfo.processInfo.systemUptime - publishDelay
        let entry = held.last { $0.time <= due } ?? oldest
        return (entry.text, entry.selection)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        Self.dawdle()
        Self.countIsFromBeforeTheKey = Self.tornSelectionReads > 0
        guard Self.tornSelectionReads > 0 else { return Self.published?.selection ?? super.accessibilitySelectedTextRange() }
        Self.tornSelectionReads -= 1
        return NSRange(location: (string as NSString).length + Self.charactersDeleted, length: 0)
    }

    override func accessibilityNumberOfCharacters() -> Int {
        Self.dawdle()
        let count = Self.published.map { ($0.text as NSString).length } ?? super.accessibilityNumberOfCharacters()
        return count + (Self.countIsFromBeforeTheKey ? Self.charactersDeleted : 0)
    }

    override func accessibilityValue() -> String? {
        Self.dawdle()
        return Self.published?.text ?? super.accessibilityValue()
    }

    override func accessibilityString(for range: NSRange) -> String? {
        Self.dawdle()
        guard let text = Self.published?.text as NSString? else { return super.accessibilityString(for: range) }
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard Self.published != nil else { return super.accessibilityAttributedString(for: range) }
        return accessibilityString(for: range).map(NSAttributedString.init(string:))
    }
}

/// Standard Edit menu, so Select All / Undo / Copy behave as they do in any Mac app.
func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu()
    appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    return main
}

let app = NSApplication.shared
app.mainMenu = makeMainMenu()
let delegate = HostDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
