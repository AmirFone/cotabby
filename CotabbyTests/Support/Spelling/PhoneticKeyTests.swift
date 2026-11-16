import XCTest
@testable import Cotabby

/// The vowel-aware sound key: sound-it-out spellings match their word, near spellings that sound
/// different do not.
final class PhoneticKeyTests: XCTestCase {
    func test_vowelKey_matchesSoundItOutSpellings() {
        let pairs = [("brawt", "brought"), ("pikcher", "picture"), ("becos", "because"), ("fone", "phone"),
                     ("skool", "school"), ("onest", "honest")]
        for (typed, word) in pairs {
            XCTAssertEqual(PhoneticKey.vowelKey(for: typed), PhoneticKey.vowelKey(for: word), "\(typed) ~ \(word)")
        }
    }

    func test_vowelKey_separatesDifferentVowelSounds() {
        XCTAssertNotEqual(PhoneticKey.vowelKey(for: "brawt"), PhoneticKey.vowelKey(for: "brat"))
        XCTAssertNotEqual(PhoneticKey.vowelKey(for: "pikcher"), PhoneticKey.vowelKey(for: "packer"))
    }

    func test_vowelKey_isEmptyForVeryShortWords() {
        XCTAssertEqual(PhoneticKey.vowelKey(for: "at"), "")
    }
}
