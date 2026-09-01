import CodenamePromiseCore
import SwiftUI

/// The photos from a day, as one picture rather than a row of stamps.
///
/// A strip of small thumbnails says "this record has four attachments". A collage says "that
/// night" — which is the reaction the list exists to produce. Same data, and the difference
/// is entirely in how much room it is given.
///
/// The layout adapts to how many there are, because four cells with two of them empty looks
/// like a bug, and one photo stretched across a 2x2 grid looks like a mistake.
struct MediaCollage: View {
    let thumbs: [DraftSummary.Thumb]
    let overflow: Int
    let fileStore: MediaFileStore

    private let gap: CGFloat = 3
    private let corner: CGFloat = 14



    var body: some View {
        Group {
            switch thumbs.count {
            case 0:
                EmptyView()
            case 1:
                cell(thumbs[0])
            case 2:
                HStack(spacing: gap) { cell(thumbs[0]); cell(thumbs[1]) }
            case 3:
                HStack(spacing: gap) {
                    cell(thumbs[0])
                    VStack(spacing: gap) { cell(thumbs[1]); cell(thumbs[2]) }
                }
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) { cell(thumbs[0]); cell(thumbs[1]) }
                    HStack(spacing: gap) {
                        cell(thumbs[2])
                        if overflow > 0 { overflowCell } else { cell(thumbs[3]) }
                    }
                }
            }
        }
        // A fixed height and a width that can only ever be the row's.
        //
        // The previous version used aspectRatio(.fit), which is free to compute a width
        // *wider* than what it was offered - and a child wider than its row does not clip,
        // it widens the row, pushing the title and text off the left edge. This is the
        // second time that has happened here, so the layout is now dimensionally incapable
        // of it rather than merely tuned not to.
        .frame(maxWidth: .infinity)
        .frame(height: thumbs.isEmpty ? 0 : height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    /// One photo gets a shorter, wider frame; a grid needs the room to be a grid.
    ///
    /// These were 150 / 118 / 176, which made every entry with photos a full screen of its
    /// own and cost the list the thing it is for. A journal list has two jobs and they pull
    /// against each other: show enough of a day to recognise it, and show enough days to scan.
    /// At the old heights the first had eaten the second - three entries filled the screen and
    /// finding last Tuesday meant scrolling rather than looking.
    ///
    /// A third smaller is still plainly a photograph and not a stamp, which is the line worth
    /// holding. Anyone who wants the gallery has the density toggle in the toolbar.
    private var height: CGFloat {
        switch thumbs.count {
        case 1: 104
        case 2: 84
        default: 116
        }
    }

    private func cell(_ thumb: DraftSummary.Thumb) -> some View {
        CollageTile(thumb: thumb, fileStore: fileStore)
    }

    /// The last cell counts what is not shown, rather than a chip floating beside the strip.
    private var overflowCell: some View {
        CollageTile(thumb: thumbs[3], fileStore: fileStore)
            .overlay {
                Rectangle().fill(.black.opacity(0.55))
                Text("+\(overflow)")
                    .font(Type.display(21, .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private struct CollageTile: View {
    let thumb: DraftSummary.Thumb
    let fileStore: MediaFileStore

    @State private var image: UIImage?

    /// The photo is an *overlay* on a flexible colour, not a sibling in a stack.
    ///
    /// This looks like a stylistic preference and is not. `scaledToFill()` reports a size that
    /// covers whatever it is proposed, which means against a fixed 176pt-tall cell a landscape
    /// photo reports a **minimum** width of 176 x its aspect ratio - about 235pt. Two of those
    /// side by side ask for more width than the row has, and `frame(maxWidth: .infinity)` does
    /// not override a child's minimum, so the collage came out ~50pt wider than the row and
    /// centred itself on the overflow: the title and preview text hung off the left edge while
    /// the photos ran past the right. `.clipped()` never helped, because clipping affects
    /// drawing and this is a sizing problem.
    ///
    /// `Color` is flexible down to zero and an overlay is laid out inside its base's frame
    /// without ever influencing it, so the tile is now exactly the size it is handed and the
    /// photo crops into it. Same picture, no opinion about width.
    ///
    /// Third time this list has been widened from the inside - see `thumbnailLimit` and the
    /// note on the collage's own frame for the first two.
    var body: some View {
        Brand.surface
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if thumb.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .padding(7)
                }
            }
            .task {
                if image == nil {
                    // Bigger than the old 140: these are display sizes now, not stamps.
                    image = await ThumbnailCache.shared.thumbnail(
                        id: thumb.id, relativePath: thumb.relativePath,
                        isVideo: thumb.isVideo, fileStore: fileStore, maxPixel: 420
                    )
                }
            }
    }
}
