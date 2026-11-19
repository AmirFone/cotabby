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
    /// UserDefaults suites made for a test's own correction memory, removed in `tearDown`.
    private var defaultsSuites: [String] = []
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
        defaultsSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        defaultsSuites.removeAll()
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

    /// What the host-publish wait does when the field shows a key of the writer: it hands the text
    /// to the spelling stages, which look at nothing a key did not put in the field.
    private func noteKeyPublished(in rig: CoordinatorRig) {
        rig.coordinator.noteTypedTextPublished(
            inField: rig.focusProvider.snapshot.context?.focusChangeSequence,
            pollGeneration: rig.coordinator.hostPublishPollGeneration
        )
    }

    /// A prediction cycle as a key of the writer starts it, minus the wait for the host. A bare
    /// `schedulePrediction()` is what a settings change or arriving screen text calls, and that
    /// leaves the text in the field alone.
    private func scheduleCycleForTypedText(in rig: CoordinatorRig) {
        noteKeyPublished(in: rig)
        rig.coordinator.schedulePrediction()
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

        scheduleCycleForTypedText(in: rig)
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
        scheduleCycleForTypedText(in: rig)
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
        XCTAssertNil(rig.coordinator.typedTextCheck)
        XCTAssertEqual(rig.inserter.replacements.count, 0)

        // #and from the writer's next key on, fixes are made as usual: they write on (the first
        // letter also dismisses the ghost text offered on switching on), slip again, and the host
        // shows the space that finishes the word
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 0, characters: "a", flags: []))
        setText(text + "and teh", in: rig)
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 49, characters: " ", flags: []))
        setText(text + "and teh ", in: rig)
        await waitUntil("The fix never reached the field") { !rig.inserter.replacements.isEmpty }
        XCTAssertEqual(rig.inserter.replacements.map(\.text), ["the "], "The word just typed is fixed, the old slip stays")
    }

    // MARK: - Only text a key just typed is checked

    func test_screenTextArrivingAfterAClickIntoAField_fixesNothing() async throws {
        // #given a field the writer clicked into, ending in a slip the engine fixes without asking
        let rig = try makeRig(text: "We met at the restarant ")
        let identity = try XCTUnwrap(rig.focusProvider.snapshot.context).identity

        // #when the screen text becomes ready and schedules a prediction, with no key pressed
        rig.visualContext.onInjectedContextReady?(identity)
        await waitUntil("The cycle never ran") { !rig.engine.requests.isEmpty }

        // #then the text nobody just typed is left as it is
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_settingChangedWhileOn_fixesNothing() async throws {
        // #given a field ending in a slip the engine fixes without asking, and Cotabby already on
        let rig = try makeRig(text: "We met at the restarant ")

        // #when a setting changes, which schedules a prediction no key asked for
        rig.coordinator.handleSuggestionSettingsChange(CotabbyTestFixtures.settingsSnapshot(
            debounceMilliseconds: 2,
            suppressCompletionsOnTypo: true,
            offerTypoCorrections: true,
            automaticallyFixTypos: true
        ))
        await waitUntil("The cycle never ran") { !rig.engine.requests.isEmpty }

        // #then the text is left as it is
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_keyThatTypesNothing_doesNotLetLaterScreenTextFixTheField() async throws {
        // #given a field ending in a slip, and an arrow key pressed in it
        let rig = try makeRig(text: "We met at the restarant ")
        let identity = try XCTUnwrap(rig.focusProvider.snapshot.context).identity
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .navigation, keyCode: 123, characters: "", flags: []))

        // #when the screen text becomes ready afterwards
        rig.visualContext.onInjectedContextReady?(identity)
        await waitUntil("The cycle never ran") { !rig.engine.requests.isEmpty }

        // #then the arrow key did not make the old text fair game
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_keyWhoseTextNeverShowsUp_fixesNothing() async throws {
        // #given the caret at the end of text ending in a slip, where forward-delete changes nothing
        let rig = try makeRig(text: "We met at the restarant ")

        // #when that key is pressed and the wait for the host gives up
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 117, characters: "", flags: []))
        await waitUntil("The cycle never ran") { !rig.engine.requests.isEmpty }

        // #then nothing was typed by the key, so nothing is fixed
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_caretClickedElsewhereAfterTyping_fixesNothingThere() async throws {
        // #given a word the writer typed and the spelling stages looked at
        let rig = try makeRig(text: "We met at the restaurant ")
        scheduleCycleForTypedText(in: rig)
        await waitUntil("The typed word's cycle never ran") { rig.engine.requests.count == 1 }

        // #when the caret is clicked to after an old slip and screen text then schedules a prediction
        setText("We met at the restarant ", in: rig)
        rig.visualContext.onInjectedContextReady?(try XCTUnwrap(rig.focusProvider.snapshot.context).identity)
        await waitUntil("The second cycle never ran") { rig.engine.requests.count == 2 }

        // #then having typed in this field earlier does not license a fix at the new caret
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    /// Puts another field (or the same one after its frame changed) under the caret.
    private func setField(_ snapshot: FocusedInputSnapshot, in rig: CoordinatorRig) {
        rig.focusProvider.snapshot = FocusSnapshot(
            applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier,
            capability: .supported,
            context: snapshot
        )
    }

    func test_keyThatMovesFocus_fixesNothingInTheFieldItLandsIn() async throws {
        // #given a key pressed in one field
        let rig = try makeRig(text: "Hello")
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 49, characters: " ", flags: []))

        // #when focus is in another field, one that ends in a slip, by the time the host answers
        setField(CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "another-field",
            precedingText: "We met at the restarant ",
            focusChangeSequence: 2
        ), in: rig)
        await waitUntil("The cycle never ran") { !rig.engine.requests.isEmpty }

        // #then that field's text is not what the key typed, and is left as it is
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_fieldThatGrowsAsTheKeyLands_stillGetsItsFix() async throws {
        // #given a text box that resizes as it fills, which gives it a new focus sequence
        let rig = try makeRig(text: "I saw teh")
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 49, characters: " ", flags: []))

        // #when the host shows the space in the same element under the new sequence
        setField(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I saw teh ", focusChangeSequence: 2), in: rig)

        // #then the word just typed is fixed as in any other field
        await waitUntil("The fix never reached the field") { rig.inserter.replacements.map(\.text) == ["the "] }
    }

    func test_predictionRunningInAnotherFieldThanTheKeys_fixesNothingThere() async throws {
        // #given a key whose text was published in one field
        let rig = try makeRig(text: "We met at the restarant ")
        noteKeyPublished(in: rig)

        // #when the prediction it scheduled runs after the writer clicked into another field
        setField(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "We met at the restarant ", focusChangeSequence: 2), in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil("The cycle never ran") { !rig.engine.requests.isEmpty }

        // #then the other field's text is left as it is
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_firstLookCancelledBeforeItRan_isNotTakenByALaterPrediction() async throws {
        // #given a published key whose prediction was cancelled before the spelling stages ran
        let rig = try makeRig(text: "We met at the restarant ")
        scheduleCycleForTypedText(in: rig)
        rig.coordinator.cancelPredictionWork()

        // #when a prediction no key asked for runs later
        rig.coordinator.schedulePrediction()
        await waitUntil("The cycle never ran") { !rig.engine.requests.isEmpty }

        // #then it does not inherit the cancelled look
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func test_predictionWithoutAKey_looksAgainAtTheWordJustTyped() async throws {
        // #given a word just typed that the engine is unsure about, so the bar was offered
        let rig = try makeRig(text: "I drive a tyoda ")
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter
        scheduleCycleForTypedText(in: rig)
        await waitUntil("The bar was never offered") { presenter.presented.count == 1 }

        // #when a prediction without a key follows while the field still reads the same, as a late
        // Jev verdict schedules one
        rig.coordinator.schedulePrediction()

        // #then the stages look at that word again
        await waitUntil("The typed word was not looked at again") { presenter.presented.count == 2 }
    }

    func test_unsureModel_opensTheBarAndTypesNothing() async throws {
        let text = "I drive a tyoda "
        let rig = try makeRig(text: text)
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter
        let (_, confidence) = engineDecision(for: text, in: rig, word: "tyoda")
        XCTAssertLessThan(try XCTUnwrap(confidence), try XCTUnwrap(rig.coordinator.autoFixModel).threshold)

        scheduleCycleForTypedText(in: rig)
        await waitUntil("The bar was never offered") { !presenter.presented.isEmpty }

        XCTAssertEqual(presenter.presented.first?.candidates.first, "tyoda")
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "An unsure fix must be offered, never typed")
    }

    func test_runTogetherWordsAndShiftSlips_areFixedOnTheSpot() async throws {
        for (text, expected) in [("They live nextdoor ", "next door "), ("I saw THe ", "The "), ("ask the kKing ", "King ")] {
            let rig = try makeRig(text: text)

            scheduleCycleForTypedText(in: rig)
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

    // MARK: - Capitals the writer typed on purpose

    /// The engine's decision for `text` on the engineering rig, optionally knowing how some words
    /// are usually written (the lookup the app builds from the technical list's capitals and the
    /// writer's own words).
    private func engineeringDecision(for text: String, usualCasing: [String: String]? = nil) throws -> TypoGateDecision {
        let rig = try makeEngineeringRig(text: text)
        return gateDecision(for: text, in: rig, usualCasing: usualCasing)
    }

    private func gateDecision(for text: String, in rig: CoordinatorRig, usualCasing: [String: String]? = nil) -> TypoGateDecision {
        var dependencies = rig.coordinator.spellingEngineDependencies
        if let usualCasing { dependencies.usualCasing = { usualCasing[$0] } }
        var settings = TypoGate.Settings(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true)
        settings.autoApplyMinimumConfidence = rig.coordinator.autoFixModel?.threshold
        return TypoGateInputs(dependencies: dependencies, precedingText: text, textAfter: "").decide(settings: settings)
    }

    /// The word typed for the writer, or nil when nothing is changed without asking.
    private func appliedFix(_ decision: TypoGateDecision) -> String? {
        if case let .applyCorrection(_, fix) = decision { return fix }
        return nil
    }

    /// The fix at the head of the bar, or nil when the decision is not an offer.
    private func firstOfferedFix(_ decision: TypoGateDecision) -> String? {
        switch decision {
        case let .offerCorrection(_, fix): return fix
        case let .offerRankedCorrection(_, candidates), let .offerChoices(_, candidates): return candidates.first?.term
        default: return nil
        }
    }

    func test_termTypedInItsOwnCapitals_isNotRecasedAsAShiftSlip() throws {
        // #given a software term whose capitals look like Shift held one letter too long

        // #when it is finished with a space, a comma or a period
        let decisions = try ["use the OAuth ", "use OAuth,", "we use JUnit "].map { try engineeringDecision(for: $0) }

        // #then nothing is done to it
        XCTAssertEqual(decisions, [.proceed, .proceed, .proceed])
    }

    func test_wordsWrittenWithTwoLeadingCapitals_areNeverRewrittenForTheWriter() throws {
        // #given a unit and a plural acronym: the dictionary holds `ghz` and `oses`, and nobody
        // writes `Ghz` or `Oses`

        // #when they are finished with a space
        let applied = try ["we use GHz ", "we use OSes "].map { appliedFix(try engineeringDecision(for: $0)) }

        // #then neither is changed without asking
        XCTAssertEqual(applied, [nil, nil])
    }

    func test_shiftSlipInABrandName_isNotFixedToACasingNobodyUses() throws {
        // #given Shift held one letter too long on a name the system checker writes as iPhone

        // #when it is finished with a space
        let applied = appliedFix(try engineeringDecision(for: "my IPhone "))

        // #then the plain capital, which is not how the name is written, is not typed in
        XCTAssertNotEqual(applied, "Iphone")
    }

    func test_shiftSlipInATermWithKnownCapitals_isFixedToThem() throws {
        // #given the usual capitals of a term, as the app knows them from its technical list

        // #when Shift was held one letter too long on it
        let applied = appliedFix(try engineeringDecision(for: "parse the JSon ", usualCasing: ["json": "JSON"]))

        // #then the fix is the term as it is written, not `Json`
        XCTAssertEqual(applied, "JSON")
    }

    func test_lowercaseTermOrCodeLikeToken_atSentenceStart_isLeftAsTyped() throws {
        // #given commands and terms whose real name is lowercase, first on a line or after a sentence
        let texts = ["kubectl ", "json ", "Done. mongodb ", "Run this:\nkubectl ", "It was fine. node-gyp ", "It was fine. k-means "]

        // #when each is finished with a space
        let decisions = try texts.map { try engineeringDecision(for: $0) }

        // #then none is given a capital
        XCTAssertEqual(decisions, Array(repeating: .proceed, count: texts.count))
    }

    func test_wordTheWriterKept_atSentenceStart_isLeftAsTyped() throws {
        // #given a command the writer chose to keep as typed
        let text = "git "
        let rig = try makeEngineeringRig(text: text)
        let memory = makeMemory()
        memory.recordKept("git")
        rig.coordinator.personalCorrectionMemory = memory

        // #when it starts a line
        let decision = gateDecision(for: text, in: rig)

        // #then it is not capitalized
        XCTAssertEqual(decision, .proceed)
    }

    func test_wordWithAKnownWayOfWritingIt_atSentenceStart_isLeftAsTyped() throws {
        // #given words the app knows how to write: two terms with capitals of their own and a
        // command the writer uses, which is lowercase
        let usualCasing = ["javascript": "JavaScript", "api": "API", "pwd": "pwd"]

        // #when each is typed in lowercase at the start of a sentence
        let decisions = try ["Done. javascript ", "api ", "pwd "].map { try engineeringDecision(for: $0, usualCasing: usualCasing) }

        // #then none is turned into a form nobody writes (`Javascript`, `Api`, `Pwd`)
        XCTAssertEqual(decisions, [.proceed, .proceed, .proceed])
    }

    func test_wordWhoseKnownFormIsItsCapital_atSentenceStart_isCapitalized() throws {
        // #given a name written with a plain first capital

        // #when it is typed in lowercase at the start of a sentence
        let applied = appliedFix(try engineeringDecision(for: "python ", usualCasing: ["python": "Python"]))

        // #then the capital is added, because that is the known form
        XCTAssertEqual(applied, "Python")
    }

    func test_ordinaryWordsAndThePronoun_areStillCapitalized() throws {
        // #given an ordinary word at the start of a sentence, a two-word fix there, and the pronoun
        // inside a sentence

        // #when each is finished with a space
        let applied = try ["hello ", "alot ", "so i "].map { appliedFix(try engineeringDecision(for: $0)) }

        // #then each gets its capital
        XCTAssertEqual(applied, ["Hello", "A lot", "I"])
    }

    func test_wordAfterAnAbbreviationWithoutInnerDots_isNotCapitalized() throws {
        // #given `eg.` and `ie.` typed without their inner dots, inside a sentence

        // #when a correct lowercase word follows
        let decisions = try ["Use fruit eg. apples ", "Bring items, ie. the "].map { try engineeringDecision(for: $0) }

        // #then it is left alone
        XCTAssertEqual(decisions, [.proceed, .proceed])
    }

    // MARK: - Fixes the writer keeps making

    /// A correction memory of its own, so nothing learned here reaches another test or the app.
    private func makeMemory() -> PersonalCorrectionMemory {
        let suite = "SuggestionCoordinatorSpellingModelTests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        return PersonalCorrectionMemory(userDefaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    /// The decision for `text` from a writer who has already made `fix` for `typo` `times` times.
    private func gateDecision(for text: String, afterFixing typo: String, to fix: String, times: Int) throws -> TypoGateDecision {
        let rig = try makeEngineeringRig(text: text)
        let memory = makeMemory()
        for _ in 0..<times { memory.recordAccepted(typo: typo, replacement: fix) }
        rig.coordinator.personalCorrectionMemory = memory
        return gateDecision(for: text, in: rig)
    }

    func test_fixMadeExactlyTwice_leadsTheBar() throws {
        // #given a slip the engine reads as `which` here, and a writer who fixed it to `with` twice
        // (`SpellingCandidateRanker.habitLeadCount`)

        // #when the slip is typed again
        let decision = try gateDecision(for: "Tell me wich ", afterFixing: "wich", to: "with", times: 2)

        // #then their fix is the first one offered
        XCTAssertEqual(firstOfferedFix(decision), "with")
    }

    func test_fixMadeExactlyTwice_isNotTypedForTheWriter() throws {
        // #given the same writer and slip

        // #when the slip is typed again
        let decision = try gateDecision(for: "Tell me wich ", afterFixing: "wich", to: "with", times: 2)

        // #then nothing is changed without asking: that starts at the third time
        XCTAssertNil(appliedFix(decision))
    }

    func test_fixMadeThreeTimes_isTypedForTheWriter() throws {
        // #given the writer has made the fix three times (`SpellingCandidateRanker.habitAutoCount`)

        // #when the slip is typed again
        let decision = try gateDecision(for: "Tell me wich ", afterFixing: "wich", to: "with", times: 3)

        // #then it is made for them
        XCTAssertEqual(appliedFix(decision), "with")
    }

    func test_fixTheEngineIsSureOfAnyway_isStillTypedAfterItWasMadeTwice() throws {
        // #given a slip the engine fixes without asking, which is how it came to be fixed twice

        // #when it is typed a third time
        let decision = try gateDecision(for: "We met at the restarant ", afterFixing: "restarant", to: "restaurant", times: 2)

        // #then it is fixed as it was the first two times, not held back for the bar
        XCTAssertEqual(appliedFix(decision), "restaurant")
    }

    func test_habit_doesNotRewriteACapitalizedNameInsideASentence() throws {
        // #given a writer who has fixed the lowercase slip `wil` to `will` three times

        // #when they type the name `Wil` inside a sentence
        let decision = try gateDecision(for: "my friend Wil ", afterFixing: "wil", to: "will", times: 3)

        // #then the name is not changed without asking
        XCTAssertNil(appliedFix(decision))
    }

    func test_habit_isStillAppliedToTheSameSlipAtTheStartOfASentence() throws {
        // #given the same writer

        // #when the slip opens a sentence, where a capital says nothing about names
        let decision = try gateDecision(for: "Wil ", afterFixing: "wil", to: "will", times: 3)

        // #then the habitual fix is made, with the sentence's capital
        XCTAssertEqual(appliedFix(decision), "Will")
    }

    func test_americanWriter_slipNearTheBritishSpelling_isFixedToTheAmericanWord() async throws {
        // #given slips of words the dictionary used to hold only in British spelling
        for (text, expected) in [("Our neighbur ", "neighbor "), ("She lost her jewlery ", "jewelry ")] {
            let rig = try makeAmericanRig(text: text)

            // #when the word is finished
            scheduleCycleForTypedText(in: rig)
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

        scheduleCycleForTypedText(in: rig)
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
        scheduleCycleForTypedText(in: rig)
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
        scheduleCycleForTypedText(in: rig)
        await waitUntil("The bar was never offered") { !presenter.presented.isEmpty }

        XCTAssertNil(rig.coordinator.preparedTypoGate)
        XCTAssertEqual(presenter.presented.first?.candidates.first, "unfortunatl")
        XCTAssertTrue(presenter.presented.first?.candidates.contains("unfortunately") == true)
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "An unfinished word is never changed")
    }

    // MARK: - Unfinished software terms and kept words are not misspellings

    func test_unfinishedSoftwareTerm_isLetThrough() throws {
        // #given the letters of bundled terms the frequency dictionary has no common word for
        let rig = try makeRig(text: "")
        rig.coordinator.technicalTerms = TechnicalVocabulary.spellingTerms()

        // #then each start is a word in progress, not a typo to put a bar on
        for start in ["we need to debounc", "deploy with cloudfo", "query the clickhou"] {
            XCTAssertEqual(engineDecision(for: start, in: rig, word: "").0, .proceed, start)
        }
    }

    func test_unfinishedKeptWord_isLetThrough() throws {
        // #given a name the writer keeps, typed up to its last letter but one
        let rig = try makeRig(text: "")
        let memory = makeMemory()
        memory.recordKept("zorvexia")
        rig.coordinator.personalCorrectionMemory = memory

        // #then it is not flagged on the way
        XCTAssertEqual(engineDecision(for: "send it to zorvexi", in: rig, word: "").0, .proceed)
    }

    // MARK: - Words left standing in a finished line

    func test_wordsLeftStanding_areTheFlaggedWordsTheEngineHasNoGoodFixFor() throws {
        // #given a line with an invented product name, a certain misspelling, and a slip with a clear fix
        let rig = try makeRig(text: "")

        // #then only the name is a candidate for being the writer's own word
        XCTAssertEqual(rig.coordinator.wordsLeftStanding(in: "we moved the zorvex data yesterday"), ["zorvex"])
        XCTAssertEqual(rig.coordinator.wordsLeftStanding(in: "I saw teh cat and it was unfortunatly gone"), [])
    }

    func test_wordsLeftStanding_leavesIdentifiersAndPathsOut() throws {
        let rig = try makeRig(text: "")

        XCTAssertEqual(rig.coordinator.wordsLeftStanding(in: "look at zorvex_qlmt and src/zorvex before lunch"), [])
    }

    func test_wordsLeftStanding_countsAWordOncePerLine() throws {
        let rig = try makeRig(text: "")

        XCTAssertEqual(rig.coordinator.wordsLeftStanding(in: "the zorvex job feeds the Zorvex table"), ["zorvex"])
    }

    // MARK: - The bar for an unfinished word waits for a pause (word strip on)

    func test_midWordTypo_withTheStripOn_keepsTheStrip_andShowsNoBarWhileTyping() async throws {
        // #given the word strip on, and a word with a slip in it that is not finished
        let text = "that was unfortunatl"
        let rig = try makeRig(text: text)
        let bar = SpellingOfferRecorder()
        let strip = StripRecorder()
        rig.coordinator.candidateOfferPresenter = bar
        rig.coordinator.wordPredictionPresenter = strip

        // #when the key is published and the cycle runs
        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")
        scheduleCycleForTypedText(in: rig)
        await waitUntil("The strip was never told the text") { strip.noted.last == text }

        // #then the strip has the word, was not taken down, and no bar is up
        XCTAssertFalse(rig.coordinator.isSpellingPendingForLastKey, "the strip may draw for this key")
        XCTAssertEqual(strip.timesHidden, 0)
        XCTAssertTrue(bar.presented.isEmpty)
    }

    func test_midWordTypo_withTheStripOn_showsTheBarOnceTheWriterStops() async throws {
        // #given the same, and nothing typed after it
        let text = "that was unfortunatl"
        let rig = try makeRig(text: text)
        let bar = SpellingOfferRecorder()
        let strip = StripRecorder()
        rig.coordinator.candidateOfferPresenter = bar
        rig.coordinator.wordPredictionPresenter = strip
        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")
        scheduleCycleForTypedText(in: rig)

        // #when the hold passes with the field unchanged
        await waitUntil("The bar never came up after the pause") { !bar.presented.isEmpty }

        // #then the bar offers the word and the strip steps aside for it
        XCTAssertTrue(bar.presented.first?.candidates.contains("unfortunately") == true)
        XCTAssertEqual(strip.timesHidden, 1)
    }

    func test_midWordTypo_withTheStripOn_aKeyBeforeThePauseEnds_showsNoBar() async throws {
        // #given a bar held back for an unfinished word
        let text = "that was unfortunatl"
        let rig = try makeRig(text: text)
        let bar = SpellingOfferRecorder()
        let strip = StripRecorder()
        rig.coordinator.candidateOfferPresenter = bar
        rig.coordinator.wordPredictionPresenter = strip
        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")
        scheduleCycleForTypedText(in: rig)
        await waitUntil("The strip was never told the text") { strip.noted.last == text }

        // #when the writer types the next letter before the hold is over
        _ = rig.coordinator.handleInputEvent(CapturedInputEvent(kind: .textMutation, keyCode: 0, characters: "y", flags: []))
        try await Task.sleep(nanoseconds: UInt64((SuggestionCoordinator.midWordBarHoldSeconds + 0.2) * 1_000_000_000))

        // #then the bar that was waiting is not shown
        XCTAssertTrue(bar.presented.isEmpty)
    }

    func test_finishedTypo_withTheStripOn_isDecidedAtOnce() throws {
        // #given the strip on and a misspelled word finished with a space
        let text = "We met at the restarant "
        let rig = try makeRig(text: text)
        rig.coordinator.wordPredictionPresenter = StripRecorder()
        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")

        // #then the fix is pending for this key, and is typed the moment the key is published
        XCTAssertTrue(rig.coordinator.isSpellingPendingForLastKey)
        noteKeyPublished(in: rig)
        XCTAssertTrue(rig.coordinator.handlePreparedTypoGateWithoutQueueing(context: rig.focusProvider.snapshot.context))
        XCTAssertEqual(rig.inserter.replacements.first?.text, "restaurant ")
    }

    func test_preparedFix_isTypedInTheSameTurnTheFieldShowsTheKey() throws {
        // #given the spelling work done at the keypress for the text the field now shows
        let text = "We met at the restarant "
        let rig = try makeRig(text: text)
        rig.coordinator.prepareTypoGate(precedingText: text, textAfter: "")
        XCTAssertTrue(rig.coordinator.isSpellingPendingForLastKey)

        // #when the host publishes the key
        noteKeyPublished(in: rig)
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

        noteKeyPublished(in: rig)
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
        noteKeyPublished(in: rig)
        XCTAssertFalse(rig.coordinator.handlePreparedTypoGateWithoutQueueing(context: rig.focusProvider.snapshot.context))

        // #when the field reads something other than the text the work was prepared for
        setText("See you tomorow ", in: rig)
        rig.coordinator.prepareTypoGate(precedingText: "See you tomorrow ", textAfter: "")
        noteKeyPublished(in: rig)

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
        scheduleCycleForTypedText(in: rig)
        await waitUntil("The fix never reached the field") { !rig.inserter.replacements.isEmpty }

        XCTAssertEqual(rig.inserter.replacements.first?.text, "tomorrow ")
        XCTAssertNil(rig.coordinator.preparedTypoGate)
    }

    func test_escapeOnTheBar_holdsTheFixBackUntilTheCaretMovesOn() async throws {
        let rig = try makeRig(text: "See you tomorow")
        rig.coordinator.noteSpellingBarDismissed()
        XCTAssertEqual(rig.coordinator.dismissedTypo?.word, "tomorow")

        setText("See you tomorow ", in: rig)
        scheduleCycleForTypedText(in: rig)
        // With the word left alone the cycle proceeds to an ordinary completion request.
        await waitUntil("The cycle never proceeded") { !rig.engine.requests.isEmpty }
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "Escape means leave this word alone")

        setText("See you tomorow and teh ", in: rig)
        scheduleCycleForTypedText(in: rig)
        await waitUntil("The next typo was not fixed") { !rig.inserter.replacements.isEmpty }
        XCTAssertNil(rig.coordinator.dismissedTypo)
        XCTAssertEqual(rig.inserter.replacements.first?.text, "the ")
    }

    func test_wrongWordAtTheCaret_isOfferedAndNeverTyped() async throws {
        let rig = try makeRig(text: "I want to go their ")
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter

        scheduleCycleForTypedText(in: rig)
        await waitUntil("The wrong word was never offered") { !presenter.presented.isEmpty }

        XCTAssertEqual(presenter.presented.first?.candidates.prefix(2), ["their", "there"])
        XCTAssertTrue(rig.inserter.replacements.isEmpty, "A wrong word is offered, never changed unasked")
    }

    func test_rightWordAtTheCaret_isLeftAlone() async throws {
        let rig = try makeRig(text: "I want to go there ")
        let presenter = SpellingOfferRecorder()
        rig.coordinator.candidateOfferPresenter = presenter

        scheduleCycleForTypedText(in: rig)
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

/// The word strip as the coordinator sees it: on, and recording what it was told.
@MainActor
private final class StripRecorder: WordPredictionPresenting {
    let replacesGhostText = true
    private(set) var noted: [String] = []
    private(set) var timesHidden = 0

    func noteTypedText(_ precedingText: String, caretRect: CGRect, focusChangeSequence: UInt64) { noted.append(precedingText) }
    func hidePredictions() { timesHidden += 1 }
    func isBehindTheKeys(_ precedingText: String) -> Bool { false }
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
