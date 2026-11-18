import CoreGraphics
import XCTest
@testable import Cotabby

/// The writer's two choices for the panels near the caret: what a stored value turns into, and the
/// numbers each choice stands for.
///
/// Three promises are locked here. A stored value the app does not know is the default, never a
/// crash or an empty panel. Regular size and Standard glass are exactly the look the panels had
/// before the options existed. And Clear glass, the default, still gives text enough ground to be
/// read over the two pages that are hardest for it: 3:1 from its veil, more at the letter edges.
final class PanelAppearanceTests: XCTestCase {
    // MARK: - Size: reading the stored choice

    func test_size_withNothingStored_isCompact() {
        // #given a writer who never opened the setting

        // #when the size is read
        let size = PanelSize(storedValue: nil)

        // #then the panels are drawn at the default, the smallest size
        XCTAssertEqual(size, .compact)
    }

    func test_size_withAnUnknownStoredValue_isTheDefault() {
        // #given a value no build ever wrote, as from a typo in Terminal

        // #when the size is read
        let size = PanelSize(storedValue: "huge")

        // #then it falls back to the default instead of failing
        XCTAssertEqual(size, PanelSize.fallback)
    }

    func test_size_readsEachStoredName() {
        // #given the three names Settings writes

        // #when each is read back
        let sizes = ["compact", "regular", "large"].map { PanelSize(storedValue: $0) }

        // #then each is the choice it names
        XCTAssertEqual(sizes, [.compact, .regular, .large])
    }

    func test_size_isReadFromItsFlatDefaultsKey() throws {
        // #given defaults where only the flat key is set, as `defaults write` would leave them
        let defaults = try makeDefaults()
        defaults.set("large", forKey: "cotabbyPanelSize")

        // #when the current size is asked for
        let size = PanelSize.current(in: defaults)

        // #then the key alone decides it
        XCTAssertEqual(size, .large)
    }

    func test_size_withANumberStoredUnderItsKey_isTheDefault() throws {
        // #given a value of the wrong type under the key
        let defaults = try makeDefaults()
        defaults.set(3, forKey: PanelSize.defaultsKey)

        // #when the current size is asked for
        let size = PanelSize.current(in: defaults)

        // #then it is the default
        XCTAssertEqual(size, PanelSize.fallback)
    }

    // MARK: - Size: the numbers

    func test_regularSize_leavesEveryTextNumberAsDesigned() {
        // #given the font sizes and the text width the panels were designed with
        let designed: [CGFloat] = [9, 10, 11, 13, 14, 420]

        // #when they pass through the Regular size
        let drawn = designed.map(PanelSize.regular.text)

        // #then none of them moves
        XCTAssertEqual(drawn, designed)
    }

    func test_regularSize_leavesEverySpacingNumberAsDesigned() {
        // #given the paddings, gaps, radii and minimum widths the panels were designed with
        let designed: [CGFloat] = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16, 64, 150]

        // #when they pass through the Regular size
        let drawn = designed.map(PanelSize.regular.space)

        // #then none of them moves
        XCTAssertEqual(drawn, designed)
    }

    func test_compactSize_drawsTheWordStripWithTheseNumbers() {
        // #given the strip's numbers at Regular: word 13 pt, key hint 9 pt, slot padding 8 by 3,
        // gap between slots 2, corner radius 10
        let size = PanelSize.compact

        // #when the strip is drawn Compact
        let drawn = [size.text(13), size.text(9), size.space(8), size.space(3), size.space(2), size.space(10)]

        // #then the word is 11 pt, the hint stops at the 8 pt floor, and the spacing loses a quarter
        XCTAssertEqual(drawn, [11, 8, 6, 2.5, 1.5, 7.5])
    }

    func test_compactSize_makesTheStripAboutFourFifthsAsTall() {
        // #given the height of a strip as its parts add up: the word's line (16 pt for 13 pt type,
        // 13 pt for 11 pt type), the slot padding above and below, the strip padding above and below
        let regularHeight: CGFloat = 16 + 2 * PanelSize.regular.space(3) + 2 * PanelSize.regular.space(2)

        // #when the same strip is drawn Compact
        let compactHeight: CGFloat = 13 + 2 * PanelSize.compact.space(3) + 2 * PanelSize.compact.space(2)

        // #then it is clearly smaller without being halved
        XCTAssertEqual(compactHeight / regularHeight, 0.8, accuracy: 0.05)
    }

    func test_largeSize_drawsTheWordStripWithTheseNumbers() {
        // #given the strip's numbers at Regular: word 13 pt, key hint 9 pt, slot padding 8 by 3
        let size = PanelSize.large

        // #when the strip is drawn Large
        let drawn = [size.text(13), size.text(9), size.space(8), size.space(3)]

        // #then everything grows by about a fifth, to the nearest half point
        XCTAssertEqual(drawn, [15.5, 11, 9.5, 3.5])
    }

    func test_noSize_drawsTextBelowTheMinimumFontSize() {
        // #given the smallest text on any panel, the 9 pt key hint

        // #when it is drawn at each size
        let drawn = PanelSize.allCases.map { $0.text(9) }

        // #then it never goes under the floor
        XCTAssertGreaterThanOrEqual(drawn.min() ?? 0, PanelSize.minimumFontSize)
    }

    // MARK: - Glass: reading the stored choice

    func test_glass_withNothingStored_isClear() {
        // #given a writer who never opened the setting

        // #when the glass is read
        let glass = PanelGlass(storedValue: nil)

        // #then the panels use the default, the most see-through glass
        XCTAssertEqual(glass, .clear)
    }

    func test_glass_withAnUnknownStoredValue_isTheDefault() {
        // #given a value no build ever wrote

        // #when the glass is read
        let glass = PanelGlass(storedValue: "frosted")

        // #then it falls back to the default instead of failing
        XCTAssertEqual(glass, PanelGlass.fallback)
    }

    func test_glass_readsEachStoredName() {
        // #given the three names Settings writes

        // #when each is read back
        let glasses = ["clear", "standard", "solid"].map { PanelGlass(storedValue: $0) }

        // #then each is the choice it names
        XCTAssertEqual(glasses, [.clear, .standard, .solid])
    }

    func test_glass_isReadFromItsFlatDefaultsKey() throws {
        // #given defaults where only the flat key is set, as `defaults write` would leave them
        let defaults = try makeDefaults()
        defaults.set("solid", forKey: "cotabbyPanelGlass")

        // #when the current glass is asked for
        let glass = PanelGlass.current(in: defaults)

        // #then the key alone decides it
        XCTAssertEqual(glass, .solid)
    }

    // MARK: - Glass: the numbers

    func test_standardGlass_changesNothingAboutTheStockSlab() {
        // #given the glass the panels had before there was a choice
        let glass = PanelGlass.standard

        // #when the chrome asks what to draw differently
        let changes = recipe(of: glass)

        // #then the answer is nothing: the page-adapting glass, the stock tint, the full sheen and
        // rim, no outline, the usual weights
        let stock = GlassRecipe(adaptsToPage: true, veil: nil, highlightStrength: 1, textOutline: nil, boldsPrimaryText: false)
        XCTAssertEqual(changes, stock)
    }

    func test_clearGlass_isAnEvenSmokedVeil() {
        // #given a writer who wants to see the document through the panel

        // #when the chrome asks for the Clear veil
        let veil = PanelGlass.clear.veil

        // #then it is one wash over the whole slab, about half strength: white at 0.40 to 0.48 in
        // light mode, black at 0.48 to 0.56 in dark mode
        XCTAssertEqual(veil, PanelGlassVeil(lightTop: 0.40, lightBottom: 0.48, darkTop: 0.48, darkBottom: 0.56))
    }

    func test_clearGlass_outlinesItsLetters() {
        // #given the Clear veil, which is too thin to carry text alone

        // #when the chrome asks how to set the text apart
        let outline = PanelGlass.clear.textOutline

        // #then every letter gets two shadows in the surface color at 0.8, half a point and two points wide
        XCTAssertEqual(outline, PanelTextOutline(opacity: 0.8, tightRadius: 0.5, softRadius: 2))
    }

    func test_onlyClearGlass_setsEveryWordSemibold() {
        // #given the three glasses

        // #when each is asked whether unselected words are drawn heavier
        let bolding = PanelGlass.allCases.filter(\.boldsPrimaryText)

        // #then only Clear does
        XCTAssertEqual(bolding, [.clear])
    }

    func test_solidGlass_hidesMostOfThePage() {
        // #given a writer who wants the same ground behind every word

        // #when the Solid veil is laid over the slab
        let veil = PanelGlass.solid.veil

        // #then 86 to 92 percent of the page is covered, in light and in dark mode
        XCTAssertEqual(veil, PanelGlassVeil(lightTop: 0.86, lightBottom: 0.92, darkTop: 0.86, darkBottom: 0.92))
    }

    func test_onSystemMaterial_clearIsDrawnAsStandard() {
        // #given macOS 14 or 15, where every panel sits on the one system material

        // #when each glass is asked what to draw there
        let drawn = PanelGlass.allCases.map(\.onSystemMaterial)

        // #then Clear falls back to Standard, and the other two are themselves
        XCTAssertEqual(drawn, [.standard, .standard, .solid])
    }

    func test_onlyStandardGlass_adaptsToThePage() {
        // #given the three glasses

        // #when each is asked whether it turns light or dark to suit the page
        let adapting = PanelGlass.allCases.filter(\.adaptsToPage)

        // #then only Standard does; the other two make their own ground for text
        XCTAssertEqual(adapting, [.standard])
    }

    // The four tests below repeat, as arithmetic, how the layers of the Clear slab composite over
    // the two pages that are hardest for it. They are sums, not measurements: nothing here knows
    // what the system glass itself adds, and the white sheen, which fades out by mid-height and
    // takes a little ground back near the tops of white letters, is left out.
    //
    // The veil alone is held to 3:1, the usual floor for large text. It is not
    // meant to reach 4.5:1: a veil that did would no longer be see-through. The outline carries
    // the text past 4.5:1 where it counts, at the edge of each letter, and the last two tests show
    // that under one stated assumption (a blurred shadow is at half strength at a straight edge).

    func test_clearVeilAlone_keepsWhiteTextAtThreeToOneOverAWhitePage() throws {
        // #given dark mode over a pure white page, the hardest page for white text, with only the
        // black veil at its thin edge as ground
        let veil = try XCTUnwrap(PanelGlass.clear.veil)
        let ground = Self.blend(0, alpha: veil.darkTop, over: 1)

        // #when the label color, white at 85 percent, is drawn on that ground
        let ratio = Self.contrast(Self.blend(1, alpha: Self.labelOpacity, over: ground), ground)

        // #then it holds 3:1 before any outline (the sum gives about 3.2:1)
        XCTAssertGreaterThanOrEqual(ratio, 3.0)
    }

    func test_clearVeilAlone_keepsBlackTextAtThreeToOneOverABlackPage() throws {
        // #given light mode over a pure black page, the hardest page for black text, with only the
        // white veil at its thin edge as ground
        let veil = try XCTUnwrap(PanelGlass.clear.veil)
        let ground = Self.blend(1, alpha: veil.lightTop, over: 0)

        // #when the label color, black at 85 percent, is drawn on that ground
        let ratio = Self.contrast(Self.blend(0, alpha: Self.labelOpacity, over: ground), ground)

        // #then it holds 3:1 before any outline (the sum gives about 3.3:1)
        XCTAssertGreaterThanOrEqual(ratio, 3.0)
    }

    func test_clearOutline_bringsWhiteLetterEdgesPastFourAndAHalfToOne() throws {
        // #given the same white page and black veil, and at the edge of a letter the outline at
        // half its strength
        let veil = try XCTUnwrap(PanelGlass.clear.veil)
        let outline = try XCTUnwrap(PanelGlass.clear.textOutline)
        let ground = Self.blend(0, alpha: outline.opacity / 2, over: Self.blend(0, alpha: veil.darkTop, over: 1))

        // #when the label color, white at 85 percent, is drawn on that ground
        let ratio = Self.contrast(Self.blend(1, alpha: Self.labelOpacity, over: ground), ground)

        // #then the letter's edge clears 4.5:1
        XCTAssertGreaterThanOrEqual(ratio, 4.5)
    }

    func test_clearOutline_bringsBlackLetterEdgesPastFourAndAHalfToOne() throws {
        // #given the same black page and white veil, and at the edge of a letter the outline at
        // half its strength
        let veil = try XCTUnwrap(PanelGlass.clear.veil)
        let outline = try XCTUnwrap(PanelGlass.clear.textOutline)
        let ground = Self.blend(1, alpha: outline.opacity / 2, over: Self.blend(1, alpha: veil.lightTop, over: 0))

        // #when the label color, black at 85 percent, is drawn on that ground
        let ratio = Self.contrast(Self.blend(0, alpha: Self.labelOpacity, over: ground), ground)

        // #then the letter's edge clears 4.5:1
        XCTAssertGreaterThanOrEqual(ratio, 4.5)
    }

    func test_solidGlass_keepsWhiteTextReadableOverAWhitePage() throws {
        // #given dark mode over a pure white page with the Solid veil at its thin edge and the white
        // sheen at its brightest as ground
        let veil = try XCTUnwrap(PanelGlass.solid.veil)
        let sheen = Self.stockSheenPeak * PanelGlass.solid.highlightStrength
        let ground = Self.blend(1, alpha: sheen, over: Self.blend(0, alpha: veil.darkTop, over: 1))

        // #when the label color, white at 85 percent, is drawn on that ground
        let ratio = Self.contrast(Self.blend(1, alpha: Self.labelOpacity, over: ground), ground)

        // #then it clears 4.5:1 from the veil alone
        XCTAssertGreaterThanOrEqual(ratio, 4.5)
    }

    // MARK: - Helpers

    /// Everything a glass asks the chrome and the word slots to draw differently, gathered so one
    /// assertion can compare all of it.
    private struct GlassRecipe: Equatable {
        let adaptsToPage: Bool
        let veil: PanelGlassVeil?
        let highlightStrength: Double
        let textOutline: PanelTextOutline?
        let boldsPrimaryText: Bool
    }

    private func recipe(of glass: PanelGlass) -> GlassRecipe {
        GlassRecipe(
            adaptsToPage: glass.adaptsToPage,
            veil: glass.veil,
            highlightStrength: glass.highlightStrength,
            textOutline: glass.textOutline,
            boldsPrimaryText: glass.boldsPrimaryText
        )
    }

    /// The opacity of the stock sheen at the top edge of a slab (`PopupTheme.gloss`).
    private static let stockSheenPeak = 0.24
    /// The system label color is black or white at this opacity.
    private static let labelOpacity = 0.85

    /// A private defaults domain that is thrown away with the test, so nothing here reads or writes
    /// the settings of the app on this Mac.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "CotabbyTests.PanelAppearance.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// One gray laid over another at `alpha`, the way the window server composites layers. Grays
    /// are sRGB values from 0 (black) to 1 (white).
    private static func blend(_ top: Double, alpha: Double, over bottom: Double) -> Double {
        top * alpha + bottom * (1 - alpha)
    }

    /// The WCAG contrast ratio between two sRGB grays.
    private static func contrast(_ first: Double, _ second: Double) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ gray: Double) -> Double {
        gray <= 0.04045 ? gray / 12.92 : pow((gray + 0.055) / 1.055, 2.4)
    }
}
