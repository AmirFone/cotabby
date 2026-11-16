import Combine
import SwiftUI

/// File overview:
/// Renders the candidate list and the auto-fix confirmation pill. A pure view of
/// `CandidateListViewModel`: keyboard navigation arrives through the global event tap and the
/// controller, so the only input handled here is a row click.

@MainActor
final class CandidateListViewModel: ObservableObject {
    struct Row: Equatable {
        let text: String
        /// Spelling confidence in [0, 1]; nil for continuation alternates.
        let confidence: Double?
    }

    enum Content: Equatable {
        case choices(header: String?, rows: [Row])
        /// iPhone-style suggestion bar: the typed word in quotes, then the best fixes.
        case bar(rows: [Row], isContextRefined: Bool)
        /// Next-word predictions: Tab takes the highlighted first word, Option+number any word.
        /// `selectedIndex` is -1 in single-line fields, where Tab moves focus instead.
        case words([String])
        case review(SentenceReviewPresentation)
        case flash(typo: String, correction: String)
        case sentenceFix([SentenceFixSegment])
    }

    @Published var content: Content = .choices(header: nil, rows: [])
    @Published var selectedIndex = 0
    @Published var acceptKeyLabel = "Tab"
}

struct CandidateListView: View {
    @ObservedObject var model: CandidateListViewModel
    let onSelect: (Int) -> Void

    var body: some View {
        Group {
            switch model.content {
            case let .choices(header, rows):
                choices(header: header, rows: rows)
            case let .bar(rows, isContextRefined):
                bar(rows: rows, isContextRefined: isContextRefined)
            case let .words(words):
                wordStrip(words)
            case let .review(review):
                reviewCard(review)
            case let .flash(typo, correction):
                flash(typo: typo, correction: correction)
            case let .sentenceFix(segments):
                sentenceFix(segments)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .popupHUDChrome()
    }

    private func choices(header: String?, rows: [CandidateListViewModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let header {
                Text(header)
                    .strikethrough(true, color: PopupTheme.secondaryText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PopupTheme.secondaryText)
                    .popupTextHalo()
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ForEach(rows.indices, id: \.self) { index in
                CandidateRowView(
                    row: rows[index],
                    isSelected: index == model.selectedIndex,
                    acceptKeyLabel: model.acceptKeyLabel
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }
        }
        .padding(4)
        .frame(minWidth: 150, alignment: .leading)
    }

    private func bar(rows: [CandidateListViewModel.Row], isContextRefined: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(PopupTheme.hairline)
                        .frame(width: 1, height: 16)
                }
                CandidateBarSlotView(
                    text: index == 0 ? "\u{201C}\(rows[index].text)\u{201D}" : rows[index].text,
                    isTyped: index == 0,
                    isSelected: index == model.selectedIndex,
                    acceptKeyLabel: model.acceptKeyLabel,
                    optionHint: "\u{2325}\(index + 1)"
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }
            if isContextRefined {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PopupTheme.secondaryText)
                    .popupTextHalo()
                    .padding(.trailing, 6)
                    .help("Ordered by reading the sentence")
            }
        }
        .padding(3)
    }

    /// Lighter than the spelling bar on purpose: it is on screen most of the time, so it should read
    /// as a hint, not a question. Each slot names the key that picks it.
    private func wordStrip(_ words: [String]) -> some View {
        HStack(spacing: 2) {
            ForEach(words.indices, id: \.self) { index in
                WordStripSlotView(
                    text: words[index],
                    keyHint: index == model.selectedIndex ? "\u{21E5}" : "\u{2325}\(index + 1)",
                    isSelected: index == model.selectedIndex
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }
        }
        .padding(2)
    }

    /// One pass over a sentence's unsure words: the sentence on top with the word under review marked,
    /// and its options below as a bar. The counter tells the writer how many decisions are left.
    private func reviewCard(_ review: SentenceReviewPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            review.pieces.reduce(Text("")) { text, piece in
                let word = Text(piece.text)
                switch piece.role {
                case .plain:
                    return text + word.foregroundColor(PopupTheme.secondaryText)
                case .pending:
                    return text + word.foregroundColor(PopupTheme.reviewText).underline(true, pattern: .dot, color: .red)
                case .current:
                    return text + word.foregroundColor(PopupTheme.reviewText).bold().underline(true, color: PopupTheme.reviewText)
                }
            }
            .font(.system(size: 13))
            .lineLimit(3)
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .popupTextHalo()
            HStack(spacing: 6) {
                bar(
                    rows: review.options.map { CandidateListViewModel.Row(text: $0, confidence: nil) },
                    isContextRefined: false
                )
                if review.total > 1 {
                    Text("\(review.position)/\(review.total)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(PopupTheme.secondaryText)
                        .popupTextHalo()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    /// The corrected sentence with changed words in green, so the writer sees exactly what Tab will
    /// change before pressing it. Clicking anywhere on the card applies it too.
    private func sentenceFix(_ segments: [SentenceFixSegment]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            segments.reduce(Text("")) { text, segment in
                let word = Text(segment.text)
                let styled: Text
                if segment.isSuggestion {
                    // Review, not a sure fix: amber with a dotted underline, the squiggle idiom.
                    styled = word.foregroundColor(PopupTheme.reviewText).bold().underline(true, pattern: .dot, color: .red)
                } else if segment.isChanged {
                    styled = word.foregroundColor(PopupTheme.changedText).bold()
                } else {
                    styled = word.foregroundColor(PopupTheme.secondaryText)
                }
                return text + styled + Text(" ")
            }
            .font(.system(size: 13))
            .lineLimit(3)
            .frame(maxWidth: 420, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if !model.acceptKeyLabel.isEmpty {
                Text(model.acceptKeyLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PopupTheme.primaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(PopupTheme.hairline))
            }
        }
        .popupTextHalo()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(0) }
    }

    private func flash(typo: String, correction: String) -> some View {
        HStack(spacing: 6) {
            Text(typo)
                .strikethrough(true, color: PopupTheme.secondaryText)
                .foregroundStyle(PopupTheme.secondaryText)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PopupTheme.secondaryText)
            Text(correction)
                .foregroundStyle(PopupTheme.changedText)
        }
        .font(.system(size: 13, weight: .medium))
        .popupTextHalo()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct CandidateBarSlotView: View {
    let text: String
    let isTyped: Bool
    let isSelected: Bool
    let acceptKeyLabel: String
    /// The Option+number that picks this slot, shown on slots Tab does not take (as on the word strip).
    let optionHint: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? PopupTheme.keyText : isTyped ? PopupTheme.secondaryText : PopupTheme.primaryText)
                .lineLimit(1)
            if isSelected {
                Text(acceptKeyLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PopupTheme.keySecondaryText)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(PopupTheme.keyHairline))
            } else {
                Text(optionHint)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(PopupTheme.secondaryText)
            }
        }
        .popupTextHalo(onKey: isSelected)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minWidth: 64)
        .popupSelectionChip(isSelected, cornerRadius: 7)
    }
}

private struct WordStripSlotView: View {
    let text: String
    let keyHint: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? PopupTheme.keyText : PopupTheme.primaryText)
                .lineLimit(1)
            if !keyHint.isEmpty {
                Text(keyHint)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? PopupTheme.keySecondaryText : PopupTheme.secondaryText)
            }
        }
        .popupTextHalo(onKey: isSelected)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .popupSelectionChip(isSelected, cornerRadius: 6)
    }
}

private struct CandidateRowView: View {
    let row: CandidateListViewModel.Row
    let isSelected: Bool
    let acceptKeyLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Text(row.text)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? PopupTheme.keyText : PopupTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let confidence = row.confidence {
                ConfidenceDots(confidence: confidence, isOnKey: isSelected)
            }
            Text(acceptKeyLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PopupTheme.keySecondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).stroke(PopupTheme.keyHairline))
                .opacity(isSelected ? 1 : 0)
        }
        .popupTextHalo(onKey: isSelected)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .popupSelectionChip(isSelected, cornerRadius: 6)
    }
}

/// Three dots filled by confidence, so the writer can tell a near-certain fix from a guess at a glance.
private struct ConfidenceDots: View {
    let confidence: Double
    /// On the bright selection key the dots take the key's dark tones instead of the label color.
    let isOnKey: Bool

    var body: some View {
        let filled = confidence >= 0.85 ? 3 : confidence >= 0.55 ? 2 : 1
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < filled
                        ? (isOnKey ? PopupTheme.keyText : PopupTheme.primaryText)
                        : (isOnKey ? PopupTheme.keyHairline : PopupTheme.hairline))
                    .frame(width: 4, height: 4)
            }
        }
        .accessibilityLabel("Confidence \(filled) of 3")
    }
}
