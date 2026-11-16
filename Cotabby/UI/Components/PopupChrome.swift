import AppKit
import SwiftUI

/// File overview:
/// One shared visual language for every Cotabby surface that floats near the caret: the candidate
/// list (spelling bar, next-word strip, sentence card), the inline emoji picker, the suggestion
/// "popup" card (mirror mode), and the macro inline preview. Routing all of them through
/// `PopupTheme`/`PopupHUDChrome` keeps them identical and lets a restyle land in one place.
///
/// The look is a slab of glass lying on the document: the host app shows through it, softened, and
/// the slab has the cues a real piece of glass has (a lit top edge, a shaded bottom edge, a rim, a
/// sheen, a shadow under it). Back to front:
///
/// 1. The system glass, which supplies the see-through part. On macOS 26 that is Liquid Glass
///    through SwiftUI's `glassEffect`; on macOS 14 and 15 it is an `NSVisualEffectView` with
///    behind-window blending (`PopupMaterialBackdrop`).
/// 2. The body of the slab and its sheen (`PopupTheme.glassShade` or `PopupTheme.materialTint`,
///    and `PopupTheme.gloss`): a thin wash, and a highlight over the upper half.
/// 3. The content, with a raised bright key behind the selected slot (`PopupSelectionChip`) and,
///    on macOS 14 and 15 only, a halo behind its text (`popupTextHalo`).
/// 4. The edges (`PopupGlassEdges`): outline, lit rim, shaded inner edge.
/// 5. The drop shadow, which is the panel window's own (`hasShadow`, set by the panel controllers
///    that want one), not something drawn here.
///
/// Why there is almost no tint: an earlier version laid a 60 to 80 percent veil over the glass to
/// guarantee contrast, and the panel read as a frosted card; nothing of the page came through. The
/// glass does not need that help. Regular Liquid Glass picks a light or a dark surface from what is
/// behind it (light over a white page, dark over a dark or colorful one) and flips the appearance
/// of the content with it, so label-colored text lands on the readable side by itself. The one
/// word that matters most, the selected one, additionally sits on a near-opaque bright key, which
/// costs no transparency anywhere else on the slab.
///
/// Why regular glass and not the clear variant: clear glass passes more light, but it does not
/// adapt to the backdrop, so a dark-mode slab over a white page has to carry enough tint of its
/// own for white text. Measured in pictures, clear glass with that tint let through no more color
/// than regular glass with none, and its text over a white page only reached about 3.5:1.
///
/// Why the depth is drawn by hand: these panels belong to an app that is never the active one, and
/// in such a window Liquid Glass renders as a plain blur, with no bending of the backdrop and no
/// lit edge of its own. Asking for the active look (`appearsActive`, an `NSGlassEffectView` placed
/// behind the content) changed nothing in pictures. So the system supplies the blur and the
/// adaptation, and every cue that says "thick glass" is a gradient or a stroke from this file,
/// which also gives macOS 14 and 15 the same slab over their material.
///
/// Why text is label-colored and never a fixed or appearance-switched color on the glass: the
/// surface can be light or dark regardless of the system setting, and it can change while the
/// panel is up. `Color.primary` follows that change reliably. The appearance-aware `NSColor`s
/// below do not always: in pictures, a text shadow built from one kept its dark variant on some
/// slots after the surface had turned light, which put a dark smudge around black letters. So
/// everything this file draws on Liquid Glass is either label-colored or a plain white or black
/// overlay that is right on a light and a dark surface alike (the edges, the shade, the sheen, the
/// key). The appearance-switched colors, the tint and the text halo, are left to macOS 14 and 15,
/// where the surface follows the system setting and cannot change under the content. The green
/// and amber word colors are the exception that remains, because they carry meaning.
///
/// The writer this fork serves is dyslexic. If a change here trades legibility for clarity, give
/// the text better ground locally before thickening the tint, and never thicken the tint back into
/// a card.
enum PopupTheme {
    /// Shared corner radius. Continuous curvature; sized to look right on both the short single-line
    /// cards (~28pt tall) and the taller two-row emoji popup (~62pt) without going pill-round.
    static let cornerRadius: CGFloat = 10

    /// The body of the slab on Liquid Glass: a trace of shade, denser toward the base, the way a
    /// real slab shows more of its own color where you look through more of it. Plain black at a few
    /// percent, the same on a light and a dark surface: over a white page it turns the slab a shade
    /// grayer than the paper (which is also what lets the white selection key stand out on it), and
    /// over anything darker it is too faint to hide what is behind.
    static let glassShade = LinearGradient(
        colors: [Color.black.opacity(0.05), Color.black.opacity(0.12)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The body of the slab on macOS 14 and 15: milky in light mode and smoky in dark mode. It is
    /// stronger than `glassShade` because the material there follows the system setting, not the
    /// page, and text needs this much ground when a dark-mode slab lands on a white document. Still
    /// well under half strength, so the backdrop stays visible through it.
    static let materialTint = LinearGradient(
        colors: [
            adaptive(light: NSColor(white: 1, alpha: 0.20), dark: NSColor(white: 0, alpha: 0.19)),
            adaptive(light: NSColor(white: 1, alpha: 0.26), dark: NSColor(white: 0, alpha: 0.28))
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The sheen across the upper half, as if a soft light above the desk reflected off the top
    /// face of the slab. Gone by mid-height so it never sits behind the lower half of the text.
    static let gloss = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.24), location: 0),
            .init(color: Color.white.opacity(0.06), location: 0.42),
            .init(color: Color.white.opacity(0), location: 0.58)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The lit rim: brightest along the top edge where the light lands, nearly gone down the sides,
    /// and a faint return along the bottom, where light that travelled through the slab leaves it.
    static let rimHighlight = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.95), location: 0),
            .init(color: Color.white.opacity(0.25), location: 0.3),
            .init(color: Color.white.opacity(0.08), location: 0.75),
            .init(color: Color.white.opacity(0.3), location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The shaded inner edge along the bottom: the thickness of the slab, seen from above.
    static let innerShade = LinearGradient(
        stops: [
            .init(color: Color.black.opacity(0), location: 0.45),
            .init(color: Color.black.opacity(0.36), location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The outermost line. It is the one edge that must show against a page of the same brightness
    /// as the glass, so it is dark on every surface.
    static let outline = Color.black.opacity(0.5)

    /// The selected slot is drawn as a raised, lit glass key (`PopupSelectionChip`): a bright face,
    /// a brighter top edge, a shaded bottom edge, a hairline around it and a small shadow under it.
    /// The face is close to opaque and bright on every surface. That is deliberate: the selected
    /// word is what Tab inserts, so it gets ground that no backdrop can take away, and a white key
    /// on smoked or milky glass is impossible to mistake for an unselected slot.
    static let keyFace = LinearGradient(
        colors: [Color.white.opacity(0.95), Color.white.opacity(0.76)],
        startPoint: .top,
        endPoint: .bottom
    )
    static let keyEdge = LinearGradient(
        stops: [
            .init(color: Color.white, location: 0),
            .init(color: Color.white.opacity(0.3), location: 0.5),
            .init(color: Color.black.opacity(0.25), location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let keyOutline = Color.black.opacity(0.2)
    static let keyShadow = Color.black.opacity(0.45)

    /// Colors for what sits on the key. The key face is bright on every surface, so these are fixed
    /// dark tones rather than label colors, which turn white on a dark surface.
    static let keyText = Color(white: 0.06)
    static let keySecondaryText = Color.black.opacity(0.62)
    static let keyHairline = Color.black.opacity(0.24)

    /// Two soft shadows in the color of the surface, drawn behind text on macOS 14 and 15
    /// (`popupTextHalo`): a tight one that outlines each stroke and a wide one that settles a faint
    /// cloud behind the word. There the surface follows the system setting instead of the page, so
    /// a letter can land on ground close to its own color; the halo puts extra tint exactly where
    /// the text is and nowhere else, and the rest of the slab stays clear.
    ///
    /// The dark halo is the stronger of the two because its worst case is the harder one: white
    /// text on a smoky slab over a white page starts near 3:1, where black text on a milky slab
    /// over a black page starts near 9:1.
    static let textHaloTight = adaptive(light: NSColor(white: 1, alpha: 0.9), dark: NSColor(white: 0, alpha: 0.95))
    static let textHaloWide = adaptive(light: NSColor(white: 1, alpha: 0.6), dark: NSColor(white: 0, alpha: 0.9))

    /// Hairline for slot dividers and keycap outlines. Derived from the label color so it darkens
    /// on a light surface and lightens on a dark one.
    static let hairline = Color.primary.opacity(0.16)

    /// Primary text is the system label color. Secondary stays deliberately stronger than the
    /// system's own secondary label (about half strength): whole sentences are set in it on the
    /// sentence card, and half-strength text over a see-through surface is hard to read.
    static let primaryText = Color.primary
    static let secondaryText = Color.primary.opacity(0.88)

    /// Words a fix changed (green) and words that still need the writer's review (amber). Each has
    /// a deep tone for light glass and a bright tone for dark glass; the stock system green and
    /// orange are tuned for dark or opaque backgrounds and wash out on a light translucent one.
    static let changedText = adaptive(
        light: NSColor(red: 0.07, green: 0.45, blue: 0.14, alpha: 1),
        dark: NSColor(red: 0.45, green: 0.85, blue: 0.45, alpha: 1)
    )
    static let reviewText = adaptive(
        light: NSColor(red: 0.64, green: 0.26, blue: 0.0, alpha: 1),
        dark: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
    )

    /// A color that picks its variant when it is drawn, from the appearance of the view drawing it.
    /// `NSColor(name:dynamicProvider:)` is AppKit's hook for that: the closure runs at draw time, so
    /// a static constant can still follow light and dark mode without reading the SwiftUI
    /// environment at every call site.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Applies the shared glass surface: body tint and sheen behind the content, the edges over it, and
/// the system glass behind everything.
///
/// On macOS 26 the glass is attached to the content itself rather than placed behind it as a sibling
/// view, which is the arrangement Apple asks for with Liquid Glass.
///
/// Nothing here animates and nothing depends on the content, so showing a panel costs the same
/// layout pass as before. The panels appear within a frame of a keystroke and have to stay that way.
struct PopupHUDChrome: ViewModifier {
    var cornerRadius: CGFloat = PopupTheme.cornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            // One effect per panel, so no `GlassEffectContainer` (that exists to merge several
            // effects) and no `interactive()` (that adds pointer-driven animation).
            slab(content, in: shape, body: PopupTheme.glassShade)
                .glassEffect(.regular, in: shape)
        } else {
            slab(content, in: shape, body: PopupTheme.materialTint)
                .background(
                    PopupMaterialBackdrop(cornerRadius: cornerRadius)
                        // The backdrop is an AppKit view; keep it out of hit testing so a click on a
                        // slot always reaches the SwiftUI tap handler above it.
                        .allowsHitTesting(false)
                )
        }
    }

    /// Everything about the slab that this file draws itself, shared by both kinds of glass.
    private func slab(_ content: Content, in shape: RoundedRectangle, body: LinearGradient) -> some View {
        content
            .background(PopupTheme.gloss, in: shape)
            .background(body, in: shape)
            // The edges are decoration over the content's border; keep them out of hit testing so a
            // click near the rim still reaches the slot under it.
            .overlay(PopupGlassEdges(shape: shape).allowsHitTesting(false))
            .clipShape(shape)
    }
}

/// The edges that make the surface read as a slab with thickness instead of a film. Three strokes,
/// each one inside the last: a dark outline, the lit rim, and the shaded inner edge at the bottom.
///
/// Generic over the shape so the strokes always follow the same outline the chrome clips to.
/// `strokeBorder` (rather than `stroke`) keeps each line inside the shape, where the clip cannot
/// cut half of it away.
private struct PopupGlassEdges<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        ZStack {
            shape.inset(by: 1.5).strokeBorder(PopupTheme.innerShade, lineWidth: 1.5)
            shape.inset(by: 0.5).strokeBorder(PopupTheme.rimHighlight, lineWidth: 1)
            shape.strokeBorder(PopupTheme.outline, lineWidth: 0.5)
        }
    }
}

/// The raised glass key behind the selected slot. See `PopupTheme.keyFace` for why it is bright.
/// It is drawn from fixed gradients and one small shadow, so it costs nothing to keep in the tree
/// for every slot (see `popupSelectionChip`).
private struct PopupSelectionChip: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(PopupTheme.keyFace)
            .overlay(shape.inset(by: 0.5).strokeBorder(PopupTheme.keyEdge, lineWidth: 1))
            .overlay(shape.strokeBorder(PopupTheme.keyOutline, lineWidth: 0.5))
            .shadow(color: PopupTheme.keyShadow, radius: 1.5, y: 1)
    }
}

/// The glass for macOS 14 and 15, where Liquid Glass does not exist.
///
/// Why an AppKit view instead of SwiftUI's `.regularMaterial`: these panels are transparent windows
/// floating over *other apps*. SwiftUI materials blur what is behind the view inside the same
/// window, and there is nothing behind it there. `NSVisualEffectView` with `.behindWindow` blending
/// asks the window server to blur what is behind the window itself, which is the host app.
///
/// SwiftUI creates one of these per panel when the panel's view tree is first built and keeps it for
/// the life of the panel. It holds no state, which is why `updateNSView` has nothing to do.
private struct PopupMaterialBackdrop: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        // The HUD material is the system's surface for small panels floating over other apps. It
        // lets the backdrop's colors through, and it follows light and dark mode like the tint and
        // the text do.
        view.material = .hudWindow
        // A material normally goes flat and gray when its window is not key. These panels are never
        // key (the writer's app keeps the keyboard), so pin the lively state.
        view.state = .active
        // Behind-window blur is composited by the window server, outside SwiftUI's drawing, so the
        // rounded corners are given to AppKit directly as a mask image rather than left to a SwiftUI
        // clip. The cap insets keep the corners fixed while the middle stretches to any panel size.
        view.maskImage = Self.maskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private static func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}

extension View {
    /// Wraps the view in the shared glass popup chrome. `cornerRadius` defaults to `PopupTheme`.
    func popupHUDChrome(cornerRadius: CGFloat = PopupTheme.cornerRadius) -> some View {
        modifier(PopupHUDChrome(cornerRadius: cornerRadius))
    }

    /// Puts the raised glass key behind the view when it is the selected one. The key stays in the
    /// view tree either way and only its opacity changes, so moving the selection never changes the
    /// shape of the tree and costs no layout.
    func popupSelectionChip(_ isSelected: Bool, cornerRadius: CGFloat) -> some View {
        background(PopupSelectionChip(cornerRadius: cornerRadius).opacity(isSelected ? 1 : 0))
    }

    /// Draws the halo behind the text in this view on macOS 14 and 15, and nothing on macOS 26,
    /// where the glass adapts to the page and a halo can end up in the wrong color (see the file
    /// overview). Text on the selection key passes `onKey`: the key is its own solid ground, and a
    /// halo there would only smudge the letters.
    func popupTextHalo(onKey: Bool = false) -> some View {
        modifier(PopupTextHalo(isOnKey: onKey))
    }
}

/// The text halo as a modifier of its own, so the choice between "halo" and "nothing" is made once,
/// by OS version, instead of at every call site.
private struct PopupTextHalo: ViewModifier {
    let isOnKey: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            // The shadows stay in the tree with a clear color on the key, so that selecting a slot
            // does not change the tree's shape.
            content
                .shadow(color: isOnKey ? .clear : PopupTheme.textHaloTight, radius: 1)
                .shadow(color: isOnKey ? .clear : PopupTheme.textHaloWide, radius: 4)
        }
    }
}
