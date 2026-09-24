import AppKit

/// A single plain text view for Cotabby's live end-to-end tests. It exists so the tests never touch
/// the writer's own apps, documents, or macOS settings: nothing is saved, and macOS's own
/// autocorrect, capitalization, and substitutions are switched off on this view only, so the tests
/// measure Cotabby alone.
final class HostDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

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
        text.isContinuousSpellCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticTextCompletionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isGrammarCheckingEnabled = false
        text.setAccessibilityIdentifier("e2e-text")
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)
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
