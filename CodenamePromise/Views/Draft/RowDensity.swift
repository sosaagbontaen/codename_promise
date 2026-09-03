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

/// An entry collapsed to its label.
///
/// Literally the card's bottom strip with nothing above it — same view, same icon, same
/// facts in the same places. That is the whole idea of the density switch: collapsing an
/// entry drops its *body*, not its identity, so nothing moves when you toggle and there is
/// no second row design to keep in step with the first.
///
/// It used to be its own layout - title, a line of little count chips, a truncated preview,
/// a stacked time and status dot - which meant two rows that had to agree by hand and drifted
/// every time the card changed.
struct CompactDraftRow: View {
    let summary: DraftSummary
    var hasDestination: Bool = false

    var body: some View {
        EntryCard {
            EntryTitleBar(
                summary: summary, showsTopEdge: false, hasDestination: hasDestination
            )
        }
    }
}

/// The card an entry sits in, drawn by the row rather than by the `List`.
///
/// A `listRowBackground` spans the whole row and knows nothing about the content inside it,
/// which is fine for a flat fill and impossible once part of the card needs its own ground.
/// The row's content is inset from the row's edges by amounts the List picks, so an inner
/// panel could never be lined up with the outer shape. Owning the shape fixes that, and puts
/// the corner radius, the hairline and the gap between cards in one place instead of three.
struct EntryCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Brand.edge, lineWidth: 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }
}
