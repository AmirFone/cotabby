import XCTest
@testable import Cotabby

/// The writer's learned phrases: keyed like the bundled table, the empty context served by initial.
@MainActor
final class PersonalPhraseModelTests: XCTestCase {
    func test_learnedSentence_countsEachWordAfterItsContexts() {
        // #given one learned sentence
        let model = PersonalPhraseModel(fileURL: nil)

        // #when it is learned
        model.learn(sentence: "We ship on Friday.")

        // #then its pairs and longer contexts are available
        XCTAssertEqual(model.pairCount(first: "ship", second: "on"), 1)
        XCTAssertEqual(model.nextWords(after: ["we", "ship"])?.counts, ["on": 1])
        XCTAssertEqual(model.nextWords(after: ["<s>"])?.counts, ["we": 1])
    }

    func test_emptyContextIsServedByPrefix() {
        let model = PersonalPhraseModel(fileURL: nil)
        model.learn(sentence: "We ship on Friday.")
        model.learn(sentence: "Ship it now.")

        XCTAssertNil(model.nextWords(after: []))
        XCTAssertEqual(model.words(startingWith: "sh")?.counts, ["ship": 2])
        XCTAssertEqual(model.words(startingWith: "sh")?.total, 6, "Friday is a name, not a word")
        XCTAssertNil(model.words(startingWith: "zz"))
    }

    func test_resetForgetsEverything() {
        let model = PersonalPhraseModel(fileURL: nil)
        model.learn(sentence: "We ship on Friday.")

        model.reset()

        XCTAssertNil(model.nextWords(after: ["we"]))
        XCTAssertNil(model.words(startingWith: "we"))
    }

    // MARK: - The button that forgets what was learned

    /// Everything Cotabby learns from a writer, each store holding something, the way the app has
    /// them when "Clear Learned Words, Phrases and Fixes" is pressed. The correction memory is on
    /// its own UserDefaults suite, never the real one.
    @MainActor
    private struct Learned {
        let phrases = PersonalPhraseModel(fileURL: nil)
        let vocabulary = PersonalVocabulary(fileURL: nil)
        let recentWriting = RecentWriting()
        let corrections: PersonalCorrectionMemory
        let defaults: UserDefaults

        func forgetEverything() {
            CotabbyAppEnvironment.forgetEverythingLearned(
                phrases: phrases, vocabulary: vocabulary, recentWriting: recentWriting, corrections: corrections
            )
        }
    }

    private func makeLearned() -> Learned {
        let suiteName = "cotabby.test.learned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let learned = Learned(corrections: PersonalCorrectionMemory(userDefaults: defaults), defaults: defaults)
        learned.phrases.learn(sentence: "We ship on Friday.")
        for _ in 0..<2 {
            learned.vocabulary.learn(
                sentence: "Ask Lindqvist about it.", isDictionaryWord: { $0 != "lindqvist" }, isAcceptedSpelling: { _ in true }
            )
        }
        learned.recentWriting.add("We ship on Friday.")
        learned.corrections.recordAccepted(typo: "dady", replacement: "daddy")
        learned.corrections.recordKept("wich")
        return learned
    }

    func test_forgetEverythingLearned_forgetsAcceptedFixes() {
        // #given a writer whose fix for a misspelling has been learned
        let learned = makeLearned()

        // #when they clear what Cotabby learned
        learned.forgetEverything()

        // #then that fix is no longer known, so it cannot be applied for them again
        XCTAssertEqual(learned.corrections.acceptedReplacements(for: "dady"), [:])
    }

    func test_forgetEverythingLearned_forgetsWordsKeptAsTyped() {
        // #given a writer who chose to keep a word as typed
        let learned = makeLearned()

        // #when they clear what Cotabby learned
        learned.forgetEverything()

        // #then the word is no longer treated as one they meant
        XCTAssertFalse(learned.corrections.isKept("wich"))
    }

    func test_forgetEverythingLearned_leavesNoLearnedFixesInDefaults() {
        // #given learned fixes and kept words saved in the app's defaults
        let learned = makeLearned()

        // #when the writer clears what Cotabby learned
        learned.forgetEverything()

        // #then neither list is still stored, so they do not come back at the next launch
        let stored = [PersonalCorrectionMemory.defaultsKey, PersonalCorrectionMemory.keptDefaultsKey]
            .filter { learned.defaults.object(forKey: $0) != nil }
        XCTAssertEqual(stored, [])
    }

    func test_forgetEverythingLearned_forgetsPhrases() {
        // #given learned phrases
        let learned = makeLearned()

        // #when the writer clears what Cotabby learned
        learned.forgetEverything()

        // #then no learned word follows another
        XCTAssertNil(learned.phrases.nextWords(after: ["we"]))
    }

    func test_forgetEverythingLearned_forgetsTheWritersOwnWords() {
        // #given a name the writer has used often enough to be learned
        let learned = makeLearned()

        // #when the writer clears what Cotabby learned
        learned.forgetEverything()

        // #then the name is gone from their vocabulary
        XCTAssertNil(learned.vocabulary.preferredCasing(of: "lindqvist"))
    }

    func test_forgetEverythingLearned_forgetsRecentSentences() {
        // #given a finished sentence the word model would be shown
        let learned = makeLearned()

        // #when the writer clears what Cotabby learned
        learned.forgetEverything()

        // #then there is nothing left to show it
        XCTAssertEqual(learned.recentWriting.texts, [])
    }

    // MARK: - The learning switch

    private func makeDefaults() -> UserDefaults {
        let suiteName = "cotabby.test.learning.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func test_learning_isOnWhenNeitherSwitchWasTouched() {
        // #given a Mac where neither switch was ever changed
        let defaults = makeDefaults()

        // #then finished sentences are learned from
        XCTAssertTrue(PersonalPhraseModel.isLearningEnabled(in: defaults))
    }

    func test_learning_isOffWhilePredictionsAreOff_evenWithTheLearningSwitchLeftOn() {
        // #given a writer who left "Learn From My Sentences" on and switched the word strip off,
        // which greys the learning switch out in Settings
        let defaults = makeDefaults()
        defaults.set(true, forKey: PersonalPhraseModel.learningDefaultsKey)
        defaults.set(false, forKey: WordPredictionController.enabledDefaultsKey)

        // #then nothing new is learned from their sentences
        XCTAssertFalse(PersonalPhraseModel.isLearningEnabled(in: defaults))
    }

    func test_learning_isOffWhenTheLearningSwitchIsOff() {
        // #given the word strip on and the learning switch off
        let defaults = makeDefaults()
        defaults.set(false, forKey: PersonalPhraseModel.learningDefaultsKey)

        // #then nothing is learned
        XCTAssertFalse(PersonalPhraseModel.isLearningEnabled(in: defaults))
    }

    func test_predictionsKey_isTheWordStripsOwnKey() {
        // #given the key the learner reads for "are predictions on", which is spelled a second time
        // because the command-line tool builds this file without the controller
        let learnersKey = PersonalPhraseModel.predictionsDefaultsKey

        // #then it is the key the Settings switch and the word strip use
        XCTAssertEqual(learnersKey, WordPredictionController.enabledDefaultsKey)
    }

    // MARK: - Which words are counted

    private func vouching(words: Set<String>, ownNames: Set<String> = []) -> PersonalPhraseModel.Vouching {
        PersonalPhraseModel.Vouching(isWord: { words.contains($0) }, isOwnName: { ownNames.contains($0) })
    }

    func test_sentenceWithAnUnknownWord_stillTeachesItsOtherWords() {
        // #given a sentence with one word nothing vouches for (a slip, or a term not yet known)
        let model = PersonalPhraseModel(fileURL: nil)

        // #when it is learned
        model.learn(sentence: "the nightly etll job failed again", vouching: vouching(words: ["the", "nightly", "job", "failed", "again"]))

        // #then the words around it are counted
        XCTAssertEqual(model.words(startingWith: "n")?.counts, ["nightly": 1])
        XCTAssertEqual(model.pairCount(first: "job", second: "failed"), 1)
    }

    func test_unknownWord_isNeverCounted() {
        // #given the same sentence
        let model = PersonalPhraseModel(fileURL: nil)

        // #when it is learned
        model.learn(sentence: "the nightly etll job failed again", vouching: vouching(words: ["the", "nightly", "job", "failed", "again"]))

        // #then the unknown spelling cannot be offered back, as a word or after the word before it
        XCTAssertNil(model.words(startingWith: "et"))
        XCTAssertEqual(model.pairCount(first: "nightly", second: "etll"), 0)
    }

    func test_wordsAfterAnUnknownWord_areCountedAfterIt() {
        // #given a sentence with an unknown word in the middle
        let model = PersonalPhraseModel(fileURL: nil)

        // #when it is learned
        model.learn(sentence: "the nightly etll job failed again", vouching: vouching(words: ["the", "nightly", "job", "failed", "again"]))

        // #then the word after it is keyed by what was typed, found again only if typed again
        XCTAssertEqual(model.pairCount(first: "etll", second: "job"), 1)
    }

    func test_ownTermWrittenWithACapital_isCountedInLowercase() {
        // #given a capitalized term of the writer's inside a sentence
        let model = PersonalPhraseModel(fileURL: nil)

        // #when the sentence is learned
        model.learn(
            sentence: "we deploy Kubernetes on Fridays",
            vouching: vouching(words: ["we", "deploy", "on"], ownNames: ["kubernetes"])
        )

        // #then the term completes from its letters; another name stays a class
        XCTAssertEqual(model.words(startingWith: "kub")?.counts, ["kubernetes": 1])
        XCTAssertNil(model.words(startingWith: "fri"))
    }

    func test_ownTerm_keepsTheNameClassInTheContextOfTheNextWord() {
        // #given a capitalized term followed by a word
        let model = PersonalPhraseModel(fileURL: nil)

        // #when the sentence is learned
        model.learn(
            sentence: "we deploy Kubernetes on Fridays",
            vouching: vouching(words: ["we", "deploy", "on"], ownNames: ["kubernetes"])
        )

        // #then the next word is keyed like the bundled table keys it, after a name
        XCTAssertEqual(model.nextWords(after: ["<name>"])?.counts, ["on": 1])
    }

    func test_withoutVouching_everyLowercaseWordCounts() {
        // #given no vouching (the measuring tool's upper bound)
        let model = PersonalPhraseModel(fileURL: nil)

        // #when a sentence with an unknown word is learned
        model.learn(sentence: "the nightly etll job failed")

        // #then the unknown word is counted too
        XCTAssertEqual(model.words(startingWith: "et")?.counts, ["etll": 1])
    }

    // MARK: - Spread: in how many texts a word appeared

    func test_wordRepeatedInOneText_hasASpreadOfOne() {
        // #given one text of two sentences that both use a word
        let model = PersonalPhraseModel(fileURL: nil)

        // #when the text is learned
        model.learn(text: ["the replay finished overnight", "the replay looks clean"])

        // #then the word was typed twice, in one text
        XCTAssertEqual(model.words(startingWith: "rep")?.counts, ["replay": 2])
        XCTAssertEqual(model.spread(of: "replay"), 1)
    }

    func test_wordUsedInTwoSittings_hasASpreadOfTwo() {
        // #given two sentences written an hour apart
        let model = PersonalPhraseModel(fileURL: nil)
        let morning = Date(timeIntervalSince1970: 1_000_000)

        // #when both use a word
        model.learn(sentence: "the replay finished overnight", at: morning)
        model.learn(sentence: "start the replay again please", at: morning.addingTimeInterval(3_600))

        // #then its spread is two
        XCTAssertEqual(model.spread(of: "replay"), 2)
    }

    func test_wordUsedInManyMessagesOfOneSitting_hasASpreadOfOne() {
        // #given five messages about one thing within a few minutes
        let model = PersonalPhraseModel(fileURL: nil)
        let start = Date(timeIntervalSince1970: 1_000_000)

        // #when each uses the word
        for minute in 0..<5 {
            model.learn(sentence: "the replay number \(minute) failed again", at: start.addingTimeInterval(Double(minute) * 60))
        }

        // #then it was used five times on one occasion
        XCTAssertEqual(model.spread(of: "replay"), 1)
    }

    func test_newWordLaterInTheSameSitting_stillGetsItsFirstSpread() {
        // #given a sitting in which one word was already counted
        let model = PersonalPhraseModel(fileURL: nil)
        let start = Date(timeIntervalSince1970: 1_000_000)
        model.learn(sentence: "the replay finished overnight", at: start)

        // #when another word is used for the first time a minute later
        model.learn(sentence: "the backfill starts after lunch", at: start.addingTimeInterval(60))

        // #then it has a spread of one, not none
        XCTAssertEqual(model.spread(of: "backfill"), 1)
    }

    func test_totalWords_countsEveryCountedWord() {
        let model = PersonalPhraseModel(fileURL: nil)

        model.learn(sentence: "the replay finished overnight")

        XCTAssertEqual(model.totalWords, 4)
    }

    func test_spread_isNotOfferedAsAContext() {
        // #given a learned sentence
        let model = PersonalPhraseModel(fileURL: nil)
        model.learn(sentence: "the replay finished overnight")

        // #then the words completed from letters are counted once each, not once more for their spread
        XCTAssertEqual(model.words(startingWith: "rep")?.total, 4)
    }

    func test_fileFromBeforeSpreadWasKept_takesEachUseAsItsOwnText() throws {
        // #given a saved file with counts and no spread
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(["": ["replay": 5]]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // #when it is loaded
        let model = PersonalPhraseModel(fileURL: url)

        // #then what was learned from it weighs what it did
        XCTAssertEqual(model.spread(of: "replay"), 5)
    }
}
