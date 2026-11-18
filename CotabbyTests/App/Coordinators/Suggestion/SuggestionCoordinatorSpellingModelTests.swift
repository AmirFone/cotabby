import XCTest
@testable import Cotabby

/// The spelling pipeline end to end inside the process: the real coordinator, the bundled
/// dictionary, pair counts and n-gram table, and both trained models, with only the text field and
/// the keystroke injector replaced by recording stand-ins. This is the check that the pieces are
/// wired together (the model's verdict reaches the inserter, the work prepared at the keystroke is
/// the work that gets used, Escape really holds a fix back); `cotabby-spell` measures how good the
/// verdicts are, and `Tools/e2e/live-smoke.sh` checks real apps.
@MainActor
final class SuggestionCoordinatorSpellingModelTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []
    private static var resources: [String: String] = [:]
    /// Building the 82k-word index takes a few seconds, so every test shares one.
    private static var sharedCorrector: SymSpellCorrector?
    private static var sharedBigrams: BigramContextModel?

    private static func corrector() throws -> SymSpellCorrector {
        if let sharedCorrector { return sharedCorrector }
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        corrector.loadForTesting(contents: try resource("frequency_dictionary_en_82_765"))
        sharedCorrector = corrector
        return corrector
    }

    private static func bigrams() throws -> BigramContextModel {
        if let sharedBigrams { return sharedBigrams }
        let model = BigramContextModel(contents: try resource("frequency_bigramdictionary_en_243_342"))
        sharedBigrams = model
        return model
    }

    override func tearDown() {
        rigs.forEach { $0.coordinator.cancelPredictionWork() }
        rigs.removeAll()
        super.tearDown()
    }

    private static func resource(_ name: String) throws -> String {
        if let cached = resources[name] { return cached }
        let url = Bundle.main.url(forResource: name, withExtension: "txt")
            ?? Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Resources")
        let contents = try String(contentsOf: try XCTUnwrap(url, "\(name).txt is not in the app bundle"), encoding: .utf8)
        resources[name] = contents
        return contents
    }

    private func makeRig(text: String) throws -> CoordinatorRig {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: text),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: true,
                automaticallyFixTypos: true
            ),
            symSpellCorrector: try Self.corrector()
        )
        rig.coordinator.bigramContextModel = try Self.bigrams()
        rig.coordinator.nextWordModel = try XCTUnwrap(NextWordModel.bundled())
        rig.coordinator.autoFixModel = try XCTUnwrap(AutoFixFeatures.bundledModel())
        rig.coordinator.wrongWordModel = try XCTUnwrap(WrongWordDetector.bundledModel())
        rigs.append(rig)
        return rig
    }

    private func setText(_ text: String, in rig: CoordinatorRig) {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: text)
        rig.focusProvider.snapshot = FocusSnapshot(
            applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier,
            capability: .supported,
            context: snapshot
        )
    }

    /// What the engine alone decides for `text`, and the model's probability for the trailing word.
    private func engineDecision(for text: String, in rig: CoordinatorRig, word: String) -> (TypoGateDecision, Double?) {
        let inputs = TypoGateInputs(dependencies: rig.coordinator.spellingEngineDependencies, precedingText: text, textAfter: "")
        var settings = TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true)
        settings.autoApplyMinimumConfidence = rig.coordinator.autoFixModel?.threshold
        let decision = inputs.decide(settings: settings)
        return (decision, inputs.autoFixConfidence(word))
    }

    func test_confidentModel_fixIsTypedIntoTheField() async throws {
        let text = "We met at the restarant "
        let rig = try makeRig(text: text)
        let (decision, confidence) = engineDecision(for: text, in: rig, word: "restarant")
        guard case let .applyCorrection(word, fix) = decision else {
            return XCTFail("Expected the model to apply a fix, got \(decision)")
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(confidence), try XCTUnwrap(rig.coordinator.autoFixModel).threshold)

        rig.coordinator.schedulePrediction()
        await waitUntil("The fix never reached the field") { !rig.inserter.replacements.isEmpty }

        XCTAssertEqual(fix, "restaurant")
        XCTAssertEqual(rig.inserter.replacements.count, 1)
        XCTAssertEqual(rig.inserter.replacements.first?.text, "restaurant ")
        XCTAssertEqual(rig.inserter.replacements.first?.deleteCount, (word + " ").utf16.count)
        XCTAssertTrue(rig.engine.requests.isEmpty, "A fixed word must not also start a completion")
    }

    func test_misspellingAfterADot_isOfferedAndNeverTypedUnasked() async throws {
        // #given a table name with a slip in its second word, finished with a space; the same slip
        // as a word of its own is one the engine fixes without asking
        let text = "The table name is users.nmae "
        let rig = try makeRig(text: text)
        let (decision, _) = engineDecision(for: text, in: rig, word: "nmae")
        let (alone, _) = engineDecision(for: "The table name is nmae ", in: rig, word: "nmae")

        // #when the coordinator sees it
        rig.coordinator.schedulePrediction()
        try await Task.sleep(nanoseconds: 300_000_000)

        // #then the fix is on offer and the field is untouched
        guard case .applyCorrection = alone else { return XCTFail("Expected the plain word to be fixed, got \(alone)") }
        switch decision {
        case let .offerCorrection(word, fix):
            XCTAssertEqual([word, fix], ["nmae", "name"])
        case let .offerChoices(word, candidates), let .offerRankedCorrection(word, candidates):
            XCTAssertEqual(word, "nmae")
            XCTAssertEqual(candidates.first?.term, "name")
        default:
            XCTFail("Expected an offer, got \(decision)")
        }
        XCTAssertEqual(rig.inserter.replacements.count, 0)
    }

    func test_wordAfterADot_isNotCapitalizedAsASentenceStart() throws {
        let text = "The table name is users.name "
        let rig = try makeRig(text: text)

        let (decision, _) = engineDecision(for: text, in: rig, word: "name")

        guard case .proceed = decision else { return XCTFail("Expected nothing to be done, got \(decision)") }
    }

    func test_textAlreadyInTheFieldWhenSwitchedBackOn_isLeftAloneUntilTheNextKey() async throws {
        // #given a slip the engine fixes without asking, typed while Cotabby was off
        let text = "We met at the restarant "
        let rig = try makeRig(text: text)
        let on = rig.coordinator.settingsSnapshot
        rig.coordinator.handleSuggestionSettingsChange(CotabbyTestFixtures.settingsSnapshot(isGloballyEnabled: false))

        // #when Cotabby is switched back on and reads the field
        rig.coordinator.handleSuggestionSettingsChange(on)
        rig.coordinator.schedulePrediction()
        try await Task.sleep(nanoseconds: 300_000_000)

        // #then nothing is typed into what was written without it
        XCTAssertTrue(rig.coordinator.leavesExistingTextAlone)
        XCTAssertEqual(rig.inserter.replacements.count, 0)

        // #and from the writer's next key on, fixes are made as usual
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 49, characters: " ", flags: []))
        XCTAssertFalse(rig.coordinator.leavesExistingTextAlone)
        rig.coordinator.schedulePrediction()
        await waitUntil("The fix never reached the field") { !rig.inserter.replacements.isEmpty }
        XCTAssertEqual(rig.inserter.replacements.first?.text, "restaurant ")
    }

    func test_unsureModel_opensTheBarAndTypesNothing() async throws {
        let text = "I drive a tyoda "
        let rig = try makeRig(text: text)
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter
        let (_, confidence) = engineDecision(for: text, in: rig, word: "tyoda")
        XCTAssertLessThan(try XCTUnwrap(confidence), try XCTUnwrap(rig.coordinator.autoFixModel).threshold)

        rig.coordinator.schedulePrediction()
        await waitUntil("The bar was never offered") { !presenter.presented.isEmpty }

        XCTAssertEqual(presenter.presented.first?.candidates.first, "tyoda")
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "An unsure fix must be offered, never typed")
    }

    func test_runTogetherWordsAndShiftSlips_areFixedOnTheSpot() async throws {
        for (text, expected) in [("They live nextdoor ", "next door "), ("I saw THe ", "The "), ("ask the kKing ", "King ")] {
            let rig = try makeRig(text: text)

            rig.coordinator.schedulePrediction()
            await waitUntil("No fix for \(text)") { !rig.inserter.replacements.isEmpty }

            XCTAssertEqual(rig.inserter.replacements.first?.text, expected, text)
        }
    }

    // MARK: - American spelling, with the dictionary as the app loads it

    private static var sharedAppCorrector: SymSpellCorrector?

    /// The dictionary plus what the app adds to it: the overrides and the common words of the
    /// supplement (`neighbor`, `jewelry`, `dataset`).
    private static func appCorrector() throws -> SymSpellCorrector {
        if let sharedAppCorrector { return sharedAppCorrector }
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        corrector.loadForTesting(
            contents: try resource("frequency_dictionary_en_82_765") + "\n" + SymSpellCorrector.englishOverrides()
                + "\n" + SymSpellCorrector.englishSupplement() + "\n" + TechnicalVocabulary.spellingLines()
        )
        sharedAppCorrector = corrector
        return corrector
    }

    /// A rig set up like the app on a Mac whose region is the United States.
    private func makeAmericanRig(text: String) throws -> CoordinatorRig {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: text),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: true,
                automaticallyFixTypos: true
            ),
            symSpellCorrector: try Self.appCorrector()
        )
        rig.coordinator.bigramContextModel = try Self.bigrams()
        rig.coordinator.nextWordModel = try XCTUnwrap(NextWordModel.bundled())
        rig.coordinator.autoFixModel = try XCTUnwrap(AutoFixFeatures.bundledModel())
        rig.coordinator.wrongWordModel = try XCTUnwrap(WrongWordDetector.bundledModel())
        rig.coordinator.americanSpellings = try XCTUnwrap(AmericanSpellings.preferredOnThisMac(region: "US"))
        rigs.append(rig)
        return rig
    }

    // MARK: - Software-engineering terms

    /// The app's dictionary and the bundled technical terms, as on a Mac with that vocabulary on.
    private func makeEngineeringRig(text: String) throws -> CoordinatorRig {
        let rig = try makeAmericanRig(text: text)
        rig.coordinator.technicalTerms = TechnicalVocabulary.spellingTerms()
        return rig
    }

    func test_engineeringTerms_areNotFlagged() throws {
        // The system checker calls every one of these misspelled.
        for text in ["we store it as jsonb ", "run it with kubectl ", "we need an upsert ", "update the backend ", "edit the config "] {
            let rig = try makeEngineeringRig(text: text)
            let word = String(text.split(separator: " ").last ?? "")

            let (decision, _) = engineDecision(for: text, in: rig, word: word)

            guard case .proceed = decision else { return XCTFail("\(word) was flagged: \(decision)") }
        }
    }

    func test_slipsNearEngineeringTerms_areFixedTowardThem() throws {
        // #given slips whose intended word the general dictionary does not have
        for (text, meant) in [("the frontned ", "frontend"), ("parse the josn ", "json"), ("check the kuberntes ", "kubernetes"),
                              ("edit the confg ", "config"), ("add a webhok ", "webhook")] {
            let rig = try makeEngineeringRig(text: text)
            let word = String(text.split(separator: " ").last ?? "")

            let (decision, _) = engineDecision(for: text, in: rig, word: word)

            // #then the term is the fix made or the first one offered
            switch decision {
            case let .applyCorrection(_, fix), let .offerCorrection(_, fix):
                XCTAssertEqual(fix.lowercased(), meant)
            case let .offerChoices(_, list), let .offerRankedCorrection(_, list):
                XCTAssertEqual(list.first?.term.lowercased(), meant)
            default:
                XCTFail("\(word): expected \(meant), got \(decision)")
            }
        }
    }

    func test_shortTermThatIsACommonSlip_isStillFixed() throws {
        // `aws` is in the strip's list and not in the spelling dictionary, so `was` with two keys
        // swapped is still caught.
        let text = "I think it aws "
        let rig = try makeEngineeringRig(text: text)

        let (decision, _) = engineDecision(for: text, in: rig, word: "aws")

        guard case let .applyCorrection(_, fix) = decision else { return XCTFail("Expected a fix, got \(decision)") }
        XCTAssertEqual(fix, "was")
    }

    func test_americanWriter_slipNearTheBritishSpelling_isFixedToTheAmericanWord() async throws {
        // #given slips of words the dictionary used to hold only in British spelling
        for (text, expected) in [("Our neighbur ", "neighbor "), ("She lost her jewlery ", "jewelry ")] {
            let rig = try makeAmericanRig(text: text)

            // #when the word is finished
            rig.coordinator.schedulePrediction()
            await waitUntil("No fix for \(text)") { !rig.inserter.replacements.isEmpty }

            // #then the American word is typed into the field
            XCTAssertEqual(rig.inserter.replacements.first?.text, expected, text)
        }
    }

    func test_americanWriter_offeredFixes_leadWithTheAmericanSpelling_once() async throws {
        // #given a slip the engine offers fixes for
        let text = "The neigborhood "
        let rig = try makeAmericanRig(text: text)
        let (decision, _) = engineDecision(for: text, in: rig, word: "neigborhood")

        // #then the first fix is the American word, and its British twin is not listed beside it
        let fixes: [String]
        switch decision {
        case let .applyCorrection(_, corrected), let .offerCorrection(_, corrected):
            fixes = [corrected]
        case let .offerRankedCorrection(_, candidates), let .offerChoices(_, candidates), let .offerRealWordFix(_, candidates):
            fixes = candidates.map(\.term)
        case .proceed, .suppress:
            return XCTFail("Expected a fix for neigborhood, got \(decision)")
        }
        XCTAssertEqual(fixes.first, "neighborhood")
        XCTAssertFalse(fixes.contains("neighbourhood"))
    }

    func test_americanWriter_ordinaryFixes_areUnchanged() async throws {
        // #given a slip that has nothing to do with spelling styles
        let text = "We met at the restarant "
        let rig = try makeAmericanRig(text: text)

        rig.coordinator.schedulePrediction()
        await waitUntil("The fix never reached the field") { !rig.inserter.replacements.isEmpty }

        XCTAssertEqual(rig.inserter.replacements.first?.text, "restaurant ")
    }

    /// Milliseconds from scheduling a cycle to the fix being handed to the inserter. A fresh word each
    /// time, so the spell checker's own caches do not hide the cost.
    private func millisecondsToFix(text: String, prepared: Bool) async throws -> Double {
        let rig = try makeRig(text: text)
        if prepared {
            rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")
            XCTAssertNotNil(rig.coordinator.preparedTypoGate)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        rig.coordinator.schedulePrediction()
        await waitUntil("No fix for \(text)") { !rig.inserter.replacements.isEmpty }
        XCTAssertNil(rig.coordinator.preparedTypoGate, "Prepared work is used once")
        return Double((rig.inserter.replacementUptimes.first ?? started) - started) / 1_000_000
    }

    func test_workPreparedAtTheKeystroke_isWhatTheGateUsesAndLeavesLittleToDo() async throws {
        // Two different misspellings of similar cost: one decided from scratch after the field is
        // read, one whose lookups already ran when the key was pressed.
        let cold = try await millisecondsToFix(text: "We met at the restarant ", prepared: false)
        let prepared = try await millisecondsToFix(text: "It was very intresting and unfortunatly ", prepared: true)

        // Both include the 1 ms debounce and a task hop. Logged for the record; the bound is loose
        // because CI machines vary, and only guards against the prepared path doing the work twice.
        print(String(format: "spelling pipeline: fix handed to the inserter %.1f ms after scheduling from scratch, "
                + "%.1f ms with the work prepared at the keystroke", cold, prepared))
        XCTAssertLessThan(prepared, 25)
    }

    func test_midWordTypo_barIsOfferedFromWorkPreparedAtTheKeystroke() async throws {
        let text = "that was unfortunatl"
        let rig = try makeRig(text: text)
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter

        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")
        rig.coordinator.schedulePrediction()
        await waitUntil("The bar was never offered") { !presenter.presented.isEmpty }

        XCTAssertNil(rig.coordinator.preparedTypoGate)
        XCTAssertEqual(presenter.presented.first?.candidates.first, "unfortunatl")
        XCTAssertTrue(presenter.presented.first?.candidates.contains("unfortunately") == true)
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "An unfinished word is never changed")
    }

    func test_preparedFix_isTypedInTheSameTurnTheFieldShowsTheKey() throws {
        // #given the spelling work done at the keypress for the text the field now shows
        let text = "We met at the restarant "
        let rig = try makeRig(text: text)
        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")
        XCTAssertTrue(rig.coordinator.isSpellingPendingForLastKey)

        // #when the host publishes the key
        let handled = rig.coordinator.handlePreparedTypoGateWithoutQueueing(context: rig.focusProvider.snapshot.context)

        // #then the fix is typed there and then, with no task in between
        XCTAssertTrue(handled)
        XCTAssertEqual(rig.inserter.replacements.first?.text, "restaurant ")
        XCTAssertNil(rig.coordinator.preparedTypoGate)
    }

    func test_preparedBar_isOfferedInTheSameTurnTheFieldShowsTheKey() throws {
        let text = "that was unfortunatl"
        let rig = try makeRig(text: text)
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter
        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")

        let handled = rig.coordinator.handlePreparedTypoGateWithoutQueueing(context: rig.focusProvider.snapshot.context)

        XCTAssertTrue(handled)
        XCTAssertEqual(presenter.presented.first?.candidates.first, "unfortunatl")
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "An unfinished word is never changed")
    }

    func test_fastLane_leavesCorrectWordsAndOtherTextToTheNormalRoute() throws {
        // #given a correctly spelled word: nothing for the gate to do
        let rig = try makeRig(text: "We met at the restaurant ")
        rig.coordinator.prepareTypoGate(precedingText: "We met at the restaurant ", textAfter: "")
        XCTAssertFalse(rig.coordinator.isSpellingPendingForLastKey)
        XCTAssertFalse(rig.coordinator.handlePreparedTypoGateWithoutQueueing(context: rig.focusProvider.snapshot.context))

        // #when the field reads something other than the text the work was prepared for
        setText("See you tomorow ", in: rig)
        rig.coordinator.prepareTypoGate(precedingText: "See you tomorrow ", textAfter: "")

        // #then the fast lane stands down
        XCTAssertFalse(rig.coordinator.handlePreparedTypoGateWithoutQueueing(context: rig.focusProvider.snapshot.context))
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_keyTheFieldAlreadyShows_isFixedWithoutWaitingForTheTextToChange() async throws {
        // #given the gate last saw `I saw teh`, and the host published the space before Cotabby's
        // key callback ran, so the field already reads `I saw teh `
        let rig = try makeRig(text: "I saw teh ")
        rig.coordinator.lastGatedPrecedingText = "I saw teh"
        let started = ContinuousClock.now

        // #when the space key's callback arrives
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 49, characters: " ", flags: []))
        await waitUntil("The fix never reached the field") { !rig.inserter.replacements.isEmpty }

        // #then the fix does not wait out the 400 ms "text never changed" ceiling
        XCTAssertEqual(rig.inserter.replacements.first?.text, "the ")
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(250))
    }

    func test_workPreparedForOtherText_isIgnored() async throws {
        let rig = try makeRig(text: "See you tomorow ")

        rig.coordinator.prepareTypoGate(precedingText: "See you tomorrow ", textAfter: "")
        rig.coordinator.schedulePrediction()
        await waitUntil("The fix never reached the field") { !rig.inserter.replacements.isEmpty }

        XCTAssertEqual(rig.inserter.replacements.first?.text, "tomorrow ")
        XCTAssertNil(rig.coordinator.preparedTypoGate)
    }

    func test_escapeOnTheBar_holdsTheFixBackUntilTheCaretMovesOn() async throws {
        let rig = try makeRig(text: "See you tomorow")
        rig.coordinator.noteSpellingBarDismissed()
        XCTAssertEqual(rig.coordinator.dismissedTypo?.word, "tomorow")

        setText("See you tomorow ", in: rig)
        rig.coordinator.schedulePrediction()
        // With the word left alone the cycle proceeds to an ordinary completion request.
        await waitUntil("The cycle never proceeded") { !rig.engine.requests.isEmpty }
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "Escape means leave this word alone")

        setText("See you tomorow and teh ", in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil("The next typo was not fixed") { !rig.inserter.replacements.isEmpty }
        XCTAssertNil(rig.coordinator.dismissedTypo)
        XCTAssertEqual(rig.inserter.replacements.first?.text, "the ")
    }

    func test_wrongWordAtTheCaret_isOfferedAndNeverTyped() async throws {
        let rig = try makeRig(text: "I want to go their ")
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter

        rig.coordinator.schedulePrediction()
        await waitUntil("The wrong word was never offered") { !presenter.presented.isEmpty }

        XCTAssertEqual(presenter.presented.first?.candidates.prefix(2), ["their", "there"])
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "A wrong word is offered, never changed unasked")
    }

    func test_rightWordAtTheCaret_isLeftAlone() async throws {
        let rig = try makeRig(text: "I want to go there ")
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter

        rig.coordinator.schedulePrediction()
        await waitUntil("The cycle never proceeded") { !rig.engine.requests.isEmpty }

        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_sentencePass_flagsAWrongWordAndLeavesTheCorrectSentenceAlone() throws {
        let rig = try makeRig(text: "")
        func proofread(_ sentence: String) -> LocalProofreadResult {
            rig.coordinator.proofreadLocally(FinishedSentence(sentence: sentence, trailingWhitespace: " ", precedingContext: ""))
        }

        let wrong = proofread("He was to tired to walk home.")
        XCTAssertEqual(wrong.autoCorrected, "He was to tired to walk home.", "A wrong word is never changed without asking")
        XCTAssertEqual(wrong.suggested, "He was too tired to walk home.")

        XCTAssertFalse(proofread("He was too tired to walk home.").hasSuggestions)
        XCTAssertEqual(proofread("I could of done it better.").autoCorrected, "I could have done it better.")
    }
}

@MainActor
private final class SpellingOfferRecorder: CandidateOfferPresenting {
    private(set) var presented: [CandidateOffer] = []
    var isShowingChoices: Bool { !presented.isEmpty }

    func presentChoices(_ offer: CandidateOffer) { presented.append(offer) }
    func armChoices(_ offer: CandidateOffer) {}
    func disarmChoices() {}
    func dismissChoices() {}
    func flashAutoCorrection(typo: String, correction: String, caretRect: CGRect) {}
}
