import CoreGraphics
import Foundation

/// File overview:
/// The two looks the writer can pick for the small glass panels near the caret (the next-word
/// strip, the spelling bar, the sentence cards): how big they are (`PanelSize`) and how much of the
/// document shows through them (`PanelGlass`).
///
/// Why this file exists:
/// The panels are drawn by SwiftUI (`CandidateListView`, `PopupHUDChrome`) and placed by AppKit
/// (`CandidateListPanelController`). Both need the same numbers, and neither is a good home for
/// them: a number that lives in a view cannot be unit tested without drawing the view. So the
/// choices, the UserDefaults keys they are stored under, and every number a choice stands for live
/// here as plain values. The views only turn these numbers into fonts, paddings and gradients.
///
/// Each choice is one flat UserDefaults string (`compact`, `clear`, ...), read every time a panel
/// is drawn, so a change in Settings, or from Terminal, shows on the next panel without a restart:
/// `defaults write <app> cotabbyPanelSize regular` and `defaults write <app> cotabbyPanelGlass standard`
/// bring back the look the panels had before these options existed.

/// How large the panels near the caret are drawn.
///
/// `regular` is the size every panel was designed at, and the views still spell their numbers at
/// that size (`size.text(13)`, `size.space(8)`). The other two sizes are those same numbers
/// multiplied, which keeps one set of proportions instead of three hand-tuned tables.
nonisolated enum PanelSize: String, CaseIterable, Identifiable, Sendable {
    case compact
    case regular
    case large

    static let defaultsKey = "cotabbyPanelSize"

    /// What a writer gets before choosing. The strip is on screen most of the time, so the default
    /// is the size that covers the least of the document.
    static let fallback: PanelSize = .compact

    /// Reads a stored choice. Anything that is not one of the three names (nothing stored yet, a
    /// typo from Terminal, a value written by a newer build) is the default, never a failure.
    init(storedValue: String?) {
        self = storedValue.flatMap(PanelSize.init(rawValue:)) ?? PanelSize.fallback
    }

    static func current(in defaults: UserDefaults = .standard) -> PanelSize {
        PanelSize(storedValue: defaults.string(forKey: defaultsKey))
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .large: "Large"
        }
    }

    /// Multiplier for everything that is set in type: font sizes, and the width a line of text may
    /// take, so a line holds about the same number of words at every size.
    ///
    /// Compact text shrinks less than compact spacing on purpose. Padding can lose a quarter and
    /// still do its job; a word at three quarters of 13 pt is under 10 pt, which is too small to
    /// read at a glance. Together the two give a strip about four fifths as wide and as tall.
    var textScale: CGFloat {
        switch self {
        case .compact: 0.85
        case .regular: 1
        case .large: 1.2
        }
    }

    /// Multiplier for everything around the type: paddings, gaps, corner radii, minimum widths.
    var spaceScale: CGFloat {
        switch self {
        case .compact: 0.75
        case .regular: 1
        case .large: 1.2
        }
    }

    /// No text is drawn smaller than this, whatever the multiplier says. It only matters for the
    /// 9 pt key hints, which would otherwise fall to 7.5 pt on Compact.
    static let minimumFontSize: CGFloat = 8

    /// A font size or a text width, given at Regular size.
    func text(_ regular: CGFloat) -> CGFloat {
        guard self != .regular else { return regular }
        return max(Self.minimumFontSize, Self.roundedToHalfPoint(regular * textScale))
    }

    /// A padding, gap, radius or minimum width, given at Regular size.
    func space(_ regular: CGFloat) -> CGFloat {
        guard self != .regular else { return regular }
        return Self.roundedToHalfPoint(regular * spaceScale)
    }

    /// Half a point is one pixel on a Retina display, so every scaled number still lands on a
    /// pixel edge there and strokes stay sharp.
    private static func roundedToHalfPoint(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }
}

/// How much of the document shows through the panels.
///
/// `standard` is the glass the panels had before this option existed, and it has no numbers here:
/// its recipe is the stock one in `PopupTheme`, left untouched. The other two are described by the
/// values below, which `PopupHUDChrome` draws.
///
/// The three differ in more than strength, because of one fact about the system glass (see the
/// overview in `PopupChrome.swift`): only the regular Liquid Glass looks at the page behind it and
/// turns light or dark to suit. Standard relies on that, so it needs almost no tint. Glass that
/// passes more light does not adapt, so Clear and Solid take their light or dark from the system
/// setting instead and lay one even veil in that color over the whole slab. Solid's veil is nearly
/// opaque. Clear's is smoked glass: about half strength, so the document still shows through it
/// everywhere, with the letters outlined and set heavier to make up for the thinner ground.
nonisolated enum PanelGlass: String, CaseIterable, Identifiable, Sendable {
    case clear
    case standard
    case solid

    static let defaultsKey = "cotabbyPanelGlass"

    /// What a writer gets before choosing: the panel that hides the least of what they wrote.
    static let fallback: PanelGlass = .clear

    /// Reads a stored choice; anything unknown or missing is the default (see `PanelSize`).
    init(storedValue: String?) {
        self = storedValue.flatMap(PanelGlass.init(rawValue:)) ?? PanelGlass.fallback
    }

    static func current(in defaults: UserDefaults = .standard) -> PanelGlass {
        PanelGlass(storedValue: defaults.string(forKey: defaultsKey))
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clear: "Clear"
        case .standard: "Standard"
        case .solid: "Solid"
        }
    }

    /// The glass to draw on macOS 14 and 15, where there is no Liquid Glass and every panel sits
    /// on one system material. That material is already a smoked surface, and Standard's tint over
    /// it is as thin as the measured contrast allows (see `PopupTheme.materialTint`), so there is
    /// nothing clearer to offer: Clear is drawn as Standard there. Solid still means Solid.
    var onSystemMaterial: PanelGlass {
        self == .clear ? .standard : self
    }

    /// Whether the slab turns light or dark to suit the page behind it (macOS 26 only; on macOS 14
    /// and 15 no glass does). True only for Standard. When it is false the slab follows the system
    /// light or dark setting, and `veil` and `textOutline` are what keep text readable on it.
    var adaptsToPage: Bool { self == .standard }

    /// The one even wash over the whole slab, in the color of the surface (white in light mode,
    /// black in dark mode). Nil for Standard, which keeps the stock tint.
    ///
    /// Clear is smoked glass: about half the page still comes through, evenly, with no shapes
    /// behind single words. (An earlier version kept the slab nearly bare and put a blurred patch
    /// behind each word instead. Seen on a real screen the patches read as smudges, not glass.)
    /// Its dark veil is the denser of the two because its worst case is the harder one. From the
    /// veil alone, at its thin edge, the label color gets about 3.2:1 as white text over a pure
    /// white page and about 3.3:1 as black text over a pure black page; with a black veil at 0.40
    /// the white text would only get 2.5:1. `PanelAppearanceTests` repeats this arithmetic and
    /// holds both at 3:1 or better. The rest of the way to comfortable reading is `textOutline`.
    ///
    /// Solid hides close to nine tenths of the page, for a writer who needs the same ground behind
    /// every word no matter what is under the panel.
    var veil: PanelGlassVeil? {
        switch self {
        case .clear: PanelGlassVeil(lightTop: 0.40, lightBottom: 0.48, darkTop: 0.48, darkBottom: 0.56)
        case .standard: nil
        case .solid: PanelGlassVeil(lightTop: 0.86, lightBottom: 0.92, darkTop: 0.86, darkBottom: 0.92)
        }
    }

    /// How much of the stock light on the slab is kept, from 0 to 1: the sheen across its upper
    /// half and the lit rim around it. Both are white. On Clear, where the veil is all the ground
    /// white text has, the full sheen would take some of that ground back, so it is turned down
    /// far enough to cost little and left strong enough that the slab still reads as glass.
    var highlightStrength: Double {
        switch self {
        case .clear: 0.6
        case .standard, .solid: 1
        }
    }

    /// The outline drawn around every letter on Clear glass, in the color of the surface. Nil for
    /// the other two: Standard needs none, and Solid's veil is ground enough with the stock halo.
    ///
    /// The veil alone leaves text near 3:1 over the worst page. The outline closes the gap where
    /// reading happens, at the edge of each stroke: it is a shadow of the letters themselves, so it
    /// darkens (or lightens) the ground exactly along their contours and nowhere else, and nothing
    /// that looks like a shape appears behind a word. Two passes: a tight one that keeps the edge
    /// crisp and a soft one that settles the ground just around it. A blurred shadow is at about
    /// half its strength right at a straight edge, and at half of 0.8 the ground there is dark
    /// (or light) enough for better than 4.5:1 on both worst pages.
    var textOutline: PanelTextOutline? {
        switch self {
        case .clear: PanelTextOutline(opacity: 0.8, tightRadius: 0.5, softRadius: 2)
        case .standard, .solid: nil
        }
    }

    /// Whether the words a writer can pick are set semibold even when they are not the selected
    /// one. On Clear they are: a thicker stroke casts a fuller outline and holds its own against
    /// whatever shows through. The selected word is then told apart by its raised key alone, which
    /// stays the most solid thing on the slab.
    var boldsPrimaryText: Bool { self == .clear }
}

/// Opacity of the surface-colored wash over a slab, at its top and bottom edge: white at the
/// `light` pair in light mode, black at the `dark` pair in dark mode. Denser toward the base, the
/// way a real slab shows more of its own color where you look through more of it.
nonisolated struct PanelGlassVeil: Equatable, Sendable {
    let lightTop: Double
    let lightBottom: Double
    let darkTop: Double
    let darkBottom: Double
}

/// The outline around letters on a slab: two shadows of the text in the surface color (white in
/// light mode, black in dark mode), both at `opacity`, blurred by `tightRadius` and `softRadius`.
nonisolated struct PanelTextOutline: Equatable, Sendable {
    let opacity: Double
    let tightRadius: CGFloat
    let softRadius: CGFloat
}
