import AppKit
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Types into the live end-to-end test host on behalf of `Tools/e2e/live-smoke.sh`, so the whole
/// pipeline (event tap → Accessibility read → spelling engine → key injection) can be exercised with
/// real keyboard events and timed, without a person at the keyboard.
///
/// Why it lives inside the app: posting keyboard events needs the Accessibility grant, and the app
/// already holds it for its own insertions. A shell script (`osascript`) only has it when the
/// terminal that runs the script was granted it separately, which is not true for every tool that
/// runs the tests. The events posted here are deliberately *not* tagged with the app's synthetic
/// marker, so the event tap treats them exactly like a person typing.
///
/// Safety: it only exists when the app is launched with `-cotabby-e2e-commands <file>`, and every
/// key is refused unless the test host (`com.cotabby.e2e-host`) is the frontmost app, so it cannot
/// type into the writer's own windows.
///
/// Protocol: the script appends one command per line to the command file and waits for one answer
/// line per command in `<file>.ack` (`ok`, or `refused <frontmost bundle id>`):
///   type<TAB>text            letters, digits and common punctuation (US layout); `\n` is Return
///   key<TAB>code[<TAB>mods]  one key by virtual key code; mods = comma list of cmd, option, shift
///   pace<TAB>milliseconds    pause between typed characters (default 45)
///   shot<TAB>file.png        picture of the test host's window and anything floating over it
///
/// Owned by `AppDelegate` for the life of the app. Runs on its own queue because a real keyboard
/// does not wait for the app's main thread either; that keeps the measured timings honest.
nonisolated final class E2EKeyDriver: @unchecked Sendable {
    static let launchArgumentKey = "cotabby-e2e-commands"
    static let hostBundleIdentifier = "com.cotabby.e2e-host"

    private let commandURL: URL
    private let acknowledgementURL: URL
    private let queue = DispatchQueue(label: "com.cotabby.e2e-key-driver")
    private let source = CGEventSource(stateID: .privateState)
    private var readOffset: UInt64 = 0
    private var pending = ""
    private var paceMicroseconds: UInt32 = 45_000
    private var timer: DispatchSourceTimer?

    /// The frontmost app's bundle id. Written on the main thread from workspace notifications and
    /// read on the driver queue, hence the lock.
    private let frontmostLock = NSLock()
    private var frontmostBundleIdentifier: String?
    private var activationObserver: NSObjectProtocol?

    /// Returns a running driver when the launch argument names a command file, otherwise nil.
    @MainActor
    static func startIfRequested() -> E2EKeyDriver? {
        guard let path = UserDefaults.standard.string(forKey: launchArgumentKey), !path.isEmpty else { return nil }
        let driver = E2EKeyDriver(commandURL: URL(fileURLWithPath: path))
        driver.start()
        return driver
    }

    private init(commandURL: URL) {
        self.commandURL = commandURL
        acknowledgementURL = URL(fileURLWithPath: commandURL.path + ".ack")
    }

    @MainActor
    private func start() {
        setFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.setFrontmost(app?.bundleIdentifier)
        }
        // Commands written before launch belong to an earlier run.
        let size = (try? FileManager.default.attributesOfItem(atPath: commandURL.path)[.size] as? NSNumber)?.uint64Value
        readOffset = size ?? 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
        CotabbyLogger.app.info("E2E key driver reading \(commandURL.path)")
    }

    private func setFrontmost(_ bundleIdentifier: String?) {
        frontmostLock.lock()
        frontmostBundleIdentifier = bundleIdentifier
        frontmostLock.unlock()
    }

    private var hostIsFrontmost: Bool {
        frontmostLock.lock()
        let noted = frontmostBundleIdentifier
        frontmostLock.unlock()
        if noted == Self.hostBundleIdentifier { return true }
        // The activation notice can trail the activation itself; ask once more before refusing.
        let current = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        setFrontmost(current)
        return current == Self.hostBundleIdentifier
    }

    private var frontmostDescription: String {
        frontmostLock.lock()
        defer { frontmostLock.unlock() }
        return frontmostBundleIdentifier ?? "none"
    }

    private func poll() {
        guard let handle = try? FileHandle(forReadingFrom: commandURL) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: readOffset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        readOffset += UInt64(data.count)
        pending += String(data: data, encoding: .utf8) ?? ""
        while let newline = pending.firstIndex(of: "\n") {
            let line = String(pending[..<newline])
            pending = String(pending[pending.index(after: newline)...])
            acknowledge(run(line) ? "ok" : "refused \(frontmostDescription)")
        }
    }

    /// Runs one command; false when a key was refused because the test host is not in front.
    private func run(_ line: String) -> Bool {
        let parts = line.components(separatedBy: "\t")
        switch parts.first {
        case "pace":
            if parts.count > 1, let milliseconds = UInt32(parts[1]) { paceMicroseconds = milliseconds * 1_000 }
            return true
        case "key":
            guard parts.count > 1, let code = UInt16(parts[1]) else { return true }
            return press(code, flags: Self.flags(named: parts.count > 2 ? parts[2] : ""))
        case "type":
            return type(parts.dropFirst().joined(separator: "\t").replacingOccurrences(of: "\\n", with: "\n"))
        case "shot":
            guard parts.count > 1 else { return true }
            return captureHostWindow(to: parts[1])
        default:
            return true
        }
    }

    private static func flags(named list: String) -> CGEventFlags {
        let names: [String: CGEventFlags] = [
            "cmd": .maskCommand, "option": .maskAlternate, "shift": .maskShift, "ctrl": .maskControl
        ]
        return list.components(separatedBy: ",").reduce(into: CGEventFlags()) { flags, name in
            if let flag = names[name] { flags.insert(flag) }
        }
    }

    private func type(_ text: String) -> Bool {
        for character in text {
            guard let key = Self.keys[character] else { continue }
            guard press(key.code, flags: key.shifted ? .maskShift : []) else { return false }
            usleep(paceMicroseconds)
        }
        return true
    }

    private func press(_ code: UInt16, flags: CGEventFlags) -> Bool {
        guard hostIsFrontmost else { return false }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
            // Set explicitly: an event otherwise inherits whatever modifiers are physically held.
            event.flags = flags
            event.post(tap: .cghidEventTap)
            if isDown { usleep(8_000) }
        }
        return true
    }

    /// Saves a picture of the test host's window, with whatever floats over it (this app's own
    /// panels), so a restyle can be checked by eye from a test run.
    ///
    /// Why here and not in the script: capturing the screen needs the Screen Recording grant, which
    /// the app holds for its visual-context feature and the script's shell usually does not.
    /// `screencapture` started as a child process is covered by the app's grant. Only the host
    /// window's rectangle is captured (plus a margin for a panel hanging over its edge), so nothing
    /// else on the writer's screen ends up in the file.
    private func captureHostWindow(to path: String) -> Bool {
        guard hostIsFrontmost else { return false }
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let windows = listed as? [[String: Any]] ?? []
        let host = NSRunningApplication.runningApplications(withBundleIdentifier: Self.hostBundleIdentifier).first
        // Layer 0 is the normal window level; the host has exactly one such window.
        let window = windows.first { entry in
            (entry[kCGWindowOwnerPID as String] as? pid_t) == host?.processIdentifier
                && (entry[kCGWindowLayer as String] as? Int) == 0
        }
        guard let boundsValue = window?[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary) else {
            CotabbyLogger.app.error("E2E shot: the test host has no window on screen")
            return true
        }
        let area = bounds.insetBy(dx: -40, dy: -40)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", "\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))", path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            CotabbyLogger.app.error("E2E shot: could not run screencapture: \(error.localizedDescription)")
        }
        return true
    }

    private func acknowledge(_ answer: String) {
        let line = Data((answer + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: acknowledgementURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: acknowledgementURL)
        }
    }

    /// US-layout virtual key codes. Characters outside the table are skipped; the tests do not use them.
    private static let keys: [Character: (code: UInt16, shifted: Bool)] = {
        let plain: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "\n": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
            "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", ":": ";", "\"": "'", "|": "\\", "<": ",", ">": ".", "?": "/",
            "~": "`"
        ]
        var table: [Character: (code: UInt16, shifted: Bool)] = [:]
        for (character, code) in plain {
            table[character] = (code, false)
            if character.isLetter, let upper = character.uppercased().first { table[upper] = (code, true) }
        }
        for (character, base) in shifted {
            if let code = plain[base] { table[character] = (code, true) }
        }
        return table
    }()
}
