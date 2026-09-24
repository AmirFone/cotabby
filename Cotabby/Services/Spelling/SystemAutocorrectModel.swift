import Combine
import Foundation

/// File overview:
/// macOS has its own autocorrect and auto-capitalization. With both it and Cotabby fixing words, the
/// two race on the same keystroke: macOS fixes `teh` at Space, Cotabby's backspace then triggers
/// macOS's "revert the autocorrection", and the word flips back or loses its space. Cotabby does
/// everything the system features do (and more) for this writer, so Settings offers to turn the
/// system ones off, and to put them back exactly as they were.
///
/// The preferences live in the global domain, which every app reads (most at launch), so the change
/// takes full effect as apps are reopened.
@MainActor
final class SystemAutocorrectModel: ObservableObject {
    static let keys = [
        "NSAutomaticSpellingCorrectionEnabled",
        "WebAutomaticSpellingCorrectionEnabled",
        "NSAutomaticCapitalizationEnabled"
    ]
    private static let savedKey = "cotabbySavedSystemAutocorrect"

    @Published private(set) var isSystemAutocorrectOn = false
    @Published private(set) var canRestore = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    nonisolated deinit {}

    func refresh() {
        isSystemAutocorrectOn = Self.keys.contains { Self.globalValue(for: $0) ?? true }
        canRestore = defaults.dictionary(forKey: Self.savedKey) != nil
    }

    func turnOff() {
        var saved: [String: Bool] = [:]
        for key in Self.keys {
            saved[key] = Self.globalValue(for: key) ?? true
            Self.setGlobal(false, for: key)
        }
        defaults.set(saved, forKey: Self.savedKey)
        refresh()
    }

    func restore() {
        guard let saved = defaults.dictionary(forKey: Self.savedKey) as? [String: Bool] else { return }
        for (key, value) in saved {
            Self.setGlobal(value, for: key)
        }
        defaults.removeObject(forKey: Self.savedKey)
        refresh()
    }

    private static func globalValue(for key: String) -> Bool? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? Bool
    }

    private static func setGlobal(_ value: Bool, for key: String) {
        CFPreferencesSetValue(
            key as CFString,
            value as CFBoolean,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleTextSubstitutionPreferencesChanged"),
            object: nil
        )
    }
}
