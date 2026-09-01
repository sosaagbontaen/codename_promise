import SwiftUI

/// How much room an entry gets.
///
/// The collage answers "what was that night". It is worse at answering "what have I got",
/// because three entries fill a phone. Both are real questions and no single layout answers
/// them both, so this is a switch rather than a compromise — the same reason Mail, Photos
/// and Files all ship one.
enum RowDensity: String, CaseIterable, Identifiable {
    /// Everything: the words, the media, the memory.
    case comfortable
    /// One line each. For finding something, or seeing the shape of a month.
    case compact

    static let storageKey = "rowDensity"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }

    var symbol: String {
        switch self {
        case .comfortable: "rectangle.grid.1x2"
        case .compact: "list.bullet"
        }
    }

    var next: RowDensity { self == .comfortable ? .compact : .comfortable }
}

/// An entry at a glance: title, when, and what is in it.
///
/// Deliberately one line of content plus one of metadata. Anything more and it stops being
/// the answer to "show me everything".
struct CompactDraftRow: View {
    let summary: DraftSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // Same rule as the comfortable row: the title is the user's, so it is set
                // in their voice even when the row is a single line.
                Text(summary.title)
                    .font(Type.journal(15.5, 600))
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if summary.mediaCount > 0 {
                        chip("photo", "\(summary.mediaCount)")
                    }
                    if summary.pendingRecordings > 0 {
                        chip("waveform", "\(summary.pendingRecordings)")
                    }
                    if summary.isFormatted {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(Brand.ai)
                    }
                    if !summary.preview.isEmpty {
                        Text(summary.preview)
                            .font(Type.journal(12))
                            .foregroundStyle(Brand.muted)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                Text(summary.edited)
                    .font(Type.caption(11))
                    .foregroundStyle(Brand.muted)
                // Status as a dot, not a sentence: at this density a word would be most of
                // the row.
                Circle()
                    .fill(dotTint)
                    .frame(width: 6, height: 6)
                    .opacity(summary.sync == .hidden ? 0 : 1)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text)
        }
        .font(Type.caption(10.5, .medium))
        .foregroundStyle(Brand.muted)
    }

    private var dotTint: Color {
        switch summary.sync {
        case .failed: Brand.failed
        case .synced: Brand.reached
        case .syncing: Brand.violet
        default: Brand.muted.opacity(0.5)
        }
    }
}
