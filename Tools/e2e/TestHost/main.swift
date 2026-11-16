import AppKit

/// A plain text view (plus a one-line field for Tab-focus checks) for Cotabby's live end-to-end tests. It exists so the tests never touch
/// the writer's own apps, documents, or macOS settings: nothing is saved, and macOS's own
/// autocorrect, capitalization, and substitutions are switched off on this view only, so the tests
/// measure Cotabby alone.
///
/// The test script talks to it through three files in the same cache folder, so it needs no
/// Accessibility grant of its own: `doc.txt` and `field.txt` mirror the two texts (rewritten within
/// 30 ms of any change, whoever made it), and each line appended to `host-commands.txt` is one of
/// `focus-text`, `focus-field`, `clear-field`, `light`, `dark`, `busy`.
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
            default: break
            }
        }
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
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
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
        let commands = folder.appendingPathComponent("host-commands.txt")
        try? Data().write(to: commands)
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
