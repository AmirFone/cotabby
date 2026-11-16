import XCTest
@testable import Cotabby

final class SymSpellTests: XCTestCase {
    private func makeSymSpell() -> SymSpell {
        let symSpell = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 7)
        // word<space>count, like the SymSpell frequency dictionary format.
        symSpell.loadDictionary(contents: """
        the 1000000
        because 90000
        name 50000
        ten 20000
        tea 15000
        receive 8000
        definitely 6000
        separate 4000
        occurred 3000
        their 70000
        there 80000
        """)
        return symSpell
    }

    func test_repeatedWord_keepsTheLargerCount() {
        // #given a word the main list undercounts, then a correction line for it
        let index = SymSpell()
        index.loadDictionary(contents: "cannot 88737\ncount 50000000\ncannot 60000000")

        // #then the correction wins, so it outranks a same-distance neighbor
        XCTAssertEqual(index.lookup("connot").first?.term, "cannot")
    }

    func test_exactMatchReturnsZeroDistance() {
        let best = makeSymSpell().bestSuggestion(for: "name")
        XCTAssertEqual(best?.term, "name")
        XCTAssertEqual(best?.distance, 0)
    }

    func test_transpositionIsDistanceOne() {
        // teh -> the via a single adjacent transposition.
        let best = makeSymSpell().bestSuggestion(for: "teh")
        XCTAssertEqual(best?.term, "the")
        XCTAssertEqual(best?.distance, 1)
    }

    func test_correctsCommonMisspellings() {
        let symSpell = makeSymSpell()
        XCTAssertEqual(symSpell.bestSuggestion(for: "recieve")?.term, "receive")
        XCTAssertEqual(symSpell.bestSuggestion(for: "becuase")?.term, "because")
        XCTAssertEqual(symSpell.bestSuggestion(for: "definately")?.term, "definitely")
        XCTAssertEqual(symSpell.bestSuggestion(for: "seperate")?.term, "separate")
        XCTAssertEqual(symSpell.bestSuggestion(for: "occured")?.term, "occurred")
    }

    func test_frequencyBreaksTiesAmongEquidistant() {
        // teh is one edit from the, ten, and tea; the most frequent (the) wins.
        let best = makeSymSpell().bestSuggestion(for: "teh")
        XCTAssertEqual(best?.term, "the")
    }

    func test_gibberishHasNoSuggestionWithinDistance() {
        XCTAssertNil(makeSymSpell().bestSuggestion(for: "qwxzy"))
    }

    func test_emptyDictionaryReturnsNil() {
        let symSpell = SymSpell()
        XCTAssertEqual(symSpell.wordCount, 0)
        XCTAssertNil(symSpell.bestSuggestion(for: "teh"))
    }

    func test_damerauOSADistances() {
        XCTAssertEqual(SymSpell.damerauOSA(Array("teh"), Array("the"), maxDistance: 2), 1)
        XCTAssertEqual(SymSpell.damerauOSA(Array("cat"), Array("cat"), maxDistance: 2), 0)
        XCTAssertEqual(SymSpell.damerauOSA(Array("kitten"), Array("sitten"), maxDistance: 2), 1)
        // Beyond the budget returns -1.
        XCTAssertEqual(SymSpell.damerauOSA(Array("abcdef"), Array("uvwxyz"), maxDistance: 2), -1)
    }

    // MARK: - Sound one slip off, and neighbors of real words

    private func makeSoundIndex() -> SymSpell {
        let index = SymSpell()
        index.loadDictionary(contents: """
        absolutely 30000000
        comfortable 20000000
        surprise 25000000
        suppress 9000000
        form 90000000
        from 2000000000
        farm 30000000
        weight 20000000
        wait 60000000
        """)
        return index
    }

    func test_approximatePhoneticMatches_reachAWordOneSoundAway() {
        let index = makeSoundIndex()

        XCTAssertEqual(index.approximatePhoneticMatches(for: "apsolootly").first?.term, "absolutely")
        XCTAssertEqual(index.approximatePhoneticMatches(for: "comfterbul").first?.term, "comfortable")
        XCTAssertEqual(index.approximatePhoneticMatches(for: "apsolootly").first?.isApproximate, true)
    }

    func test_approximatePhoneticMatches_leaveExactSoundMatchesToTheExactIndex() {
        let index = makeSoundIndex()

        XCTAssertTrue(index.phoneticMatches(for: "suprize").contains { $0.term == "surprise" }
            || index.approximatePhoneticMatches(for: "suprize").contains { $0.term == "surprise" })
        XCTAssertFalse(index.approximatePhoneticMatches(for: "absolootly").contains { $0.term == "absolutely" && !$0.isApproximate })
        XCTAssertTrue(index.approximatePhoneticMatches(for: "xyzzyq").isEmpty)
    }

    func test_neighbors_ofARealWordSkipTheWordItself() {
        let index = makeSoundIndex()

        XCTAssertEqual(index.lookup("form").map(\.term), ["form"])
        XCTAssertEqual(Set(index.neighbors(of: "form", maxEditDistance: 1).map(\.term)), ["from", "farm"])
    }

    func test_splits_readARunTogetherWordAsTwoCommonWords() {
        let index = SymSpell()
        index.loadDictionary(contents: "next 90000000\ndoor 50000000\nwell 80000000\nto 900000000\nex 2000000")

        XCTAssertEqual(index.splits(of: "nextdoor"), [SymSpellSplit(first: "next", second: "door", minimumCount: 50_000_000)])
        XCTAssertEqual(index.splits(of: "wellto").map(\.first), ["well"])
        XCTAssertTrue(index.splits(of: "nextdoorz").isEmpty)
        XCTAssertTrue(index.splits(of: "to").isEmpty)
    }

    func test_soundsIdentical_findsTheSameSoundingWord() {
        let index = makeSoundIndex()

        XCTAssertEqual(index.soundsIdentical(to: "wait").map(\.term), ["weight"])
        XCTAssertEqual(index.count(of: "weight"), 20_000_000)
        XCTAssertEqual(index.count(of: "nope"), 0)
    }
}
