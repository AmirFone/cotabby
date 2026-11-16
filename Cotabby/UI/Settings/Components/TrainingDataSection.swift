import AppKit
import SwiftUI

/// File overview:
/// The Writing pane's "Training Data" section: the switch for the training record (`TrainingLog`),
/// how much is saved, and the three things the writer can do with it (export, look, delete).
///
/// It is its own view because the wording is the feature. Saving whole sentences is the one thing
/// in Cotabby that could be mistaken for keystroke logging, so the row says what is saved, what is
/// never saved, where it lives, and that it is off until switched on, right next to the switch.
/// Keeping that text and its controls in one small file makes it hard to change one without
/// rereading the other. Built from the same rows as the rest of the pane; it owns no styling.
struct TrainingDataSection: View {
    let trainingLog: TrainingLog
    /// `@AppStorage` reads and writes one UserDefaults key and redraws the view when it changes;
    /// `TrainingLog` reads the same key every time it is about to save.
    @AppStorage(TrainingLog.enabledDefaultsKey) private var savesExamples = false
    @State private var sentenceCount = 0
    @State private var exportStatus: String?
    @State private var isConfirmingDelete = false

    var body: some View {
        Section("Training Data") {
            Toggle(isOn: $savesExamples) {
                SettingsRowLabel(
                    title: "Save Training Examples",
                    description: "Off unless you turn it on. Saves each sentence you finish while Cotabby is working: " +
                        "what you first typed, what it became, and which fixes you kept or rejected, so a spelling " +
                        "model can be trained on your own writing. This is not a keystroke log: nothing from " +
                        "password fields, nothing typed while Cotabby is off, paused, or disabled for an app, and " +
                        "no keys, shortcuts, app names, or times of day. Stored only on this Mac and never " +
                        "uploaded; it leaves only if you export the file and send it somewhere yourself.",
                    systemImage: "graduationcap"
                )
            }
            .settingsItem(.trainingData)

            LabeledContent {
                HStack {
                    Button("Export…") { export() }
                        .disabled(sentenceCount == 0)
                    Button("Show in Finder") {
                        if let url = trainingLog.fileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(sentenceCount == 0)
                    Button("Delete All", role: .destructive) { isConfirmingDelete = true }
                        .disabled(sentenceCount == 0)
                }
            } label: {
                Text(Self.summary(sentenceCount: sentenceCount, isSaving: savesExamples))
                if let exportStatus {
                    Text(exportStatus)
                }
            }
        }
        .onAppear { sentenceCount = trainingLog.sentenceCount() }
        .confirmationDialog(
            "Delete all saved training examples?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                trainingLog.clear()
                sentenceCount = 0
                exportStatus = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved sentences are removed from this Mac. Files you already exported are not touched. This can't be undone.")
        }
    }

    /// The line next to the buttons. It says "saving" or "not saving" in words, because the switch
    /// above may have scrolled out of view.
    nonisolated static func summary(sentenceCount: Int, isSaving: Bool) -> String {
        let saved: String
        switch sentenceCount {
        case 0: saved = "Nothing saved"
        case 1: saved = "1 sentence saved"
        default: saved = "\(sentenceCount.formatted()) sentences saved"
        }
        return isSaving ? "\(saved). Saving is on." : "\(saved). Saving is off."
    }

    /// Asks where to put the file, then writes the examples there. The save panel is the system's
    /// own, so the writer picks the place and sees the name before anything is written.
    private func export() {
        let panel = NSSavePanel()
        panel.title = "Export Training Examples"
        panel.nameFieldStringValue = "cotabby-training-\(Date().formatted(.iso8601.year().month().day())).jsonl"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try trainingLog.export(to: url)
            exportStatus = "Exported \(count.formatted()) examples to \(url.lastPathComponent)."
        } catch {
            exportStatus = "Could not export: \(error.localizedDescription)"
        }
    }
}
