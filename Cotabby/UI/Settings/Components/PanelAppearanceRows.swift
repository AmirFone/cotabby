import SwiftUI

/// File overview:
/// The two Writing-pane rows that set how the panels near the caret look: "Suggestion Size"
/// (`PanelSize`) and "Glass" (`PanelGlass`).
///
/// It is its own view so the pane does not have to know how these two are stored. Neither goes
/// through `SuggestionSettingsModel`: like the other fork switches in this pane, each is one flat
/// UserDefaults key that the feature reads for itself, here the panel views on every draw. That is
/// also why there is nothing to wire up between this view and the panels: writing the key is the
/// whole change, and the next panel shown has the new look.
///
/// The body is two rows with no `Section` around them, so the pane decides which section they
/// belong to. Built from the same rows as the rest of the pane; it owns no styling.
struct PanelAppearanceRows: View {
    /// `@AppStorage` reads and writes one UserDefaults key and redraws the view when it changes.
    /// The values are kept as the raw strings and turned into choices by `PanelSize(storedValue:)`
    /// and `PanelGlass(storedValue:)`, the same readers the panels use, so a missing or unknown
    /// value shows here as the default the panels are actually drawing.
    @AppStorage(PanelSize.defaultsKey) private var storedSize: String?
    @AppStorage(PanelGlass.defaultsKey) private var storedGlass: String?

    var body: some View {
        Picker(selection: sizeBinding) {
            ForEach(PanelSize.allCases) { size in
                Text(size.displayName).tag(size)
            }
        } label: {
            SettingsRowLabel(
                title: "Suggestion Size",
                description: "How large the word strip, the spelling bar and the sentence cards are drawn. " +
                    "Compact covers the least of your text.",
                systemImage: "textformat.size"
            )
        }
        .pickerStyle(.segmented)

        Picker(selection: glassBinding) {
            ForEach(PanelGlass.allCases) { glass in
                Text(glass.displayName).tag(glass)
            }
        } label: {
            SettingsRowLabel(
                title: "Glass",
                description: "How much of your document shows through the panels. Clear is smoked glass: the " +
                    "document shows through and the words are drawn bolder with a fine outline. Solid hides " +
                    "the document for the strongest contrast.",
                systemImage: "drop.halffull"
            )
        }
        .pickerStyle(.segmented)
    }

    /// A `Binding` is a getter and a setter the picker calls; these two translate between the
    /// stored string and the choice it stands for.
    private var sizeBinding: Binding<PanelSize> {
        Binding(
            get: { PanelSize(storedValue: storedSize) },
            set: { storedSize = $0.rawValue }
        )
    }

    private var glassBinding: Binding<PanelGlass> {
        Binding(
            get: { PanelGlass(storedValue: storedGlass) },
            set: { storedGlass = $0.rawValue }
        )
    }
}
