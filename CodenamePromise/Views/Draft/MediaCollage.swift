import CodenamePromiseCore
import SwiftUI

/// The photos from a day, in one band.
///
/// It was a collage - a big cell beside a stacked column at three, a 2x2 grid at four - which
/// gave a day's photos real presence but made every entry with pictures most of a screen. A
/// grid is a gallery idiom: it is for browsing pictures, and browsing pictures is not what
/// this list is for. A single band is the filmstrip idiom, which is for *recognising* a day,
/// and it is a row shorter by construction.
///
/// One photo still gets the full width, because a lone image in a strip of one is just an
/// image, and cropping it to band height would throw away the one picture there is.
struct MediaCollage: View {
    let thumbs: [DraftSummary.Thumb]
    let overflow: Int
    let fileStore: MediaFileStore

    private let gap: CGFloat = 3
    /// Smaller than the card's 14, not equal to it.
    ///
    /// Concentric rounding: a shape inset inside another wants a *smaller* radius, roughly the
    /// outer radius minus the inset. Two nested rectangles sharing a radius is one of the
    /// reliable tells of a layout nobody looked at twice - the corners visibly disagree, and
    /// the eye reads it as a mistake without being able to say why.
    private let corner: CGFloat = 8



    var body: some View {
        Group {
            if thumbs.isEmpty {
                EmptyView()
            } else if thumbs.count == 1 {
                cell(thumbs[0])
            } else {
                HStack(spacing: gap) {
                    ForEach(Array(thumbs.enumerated()), id: \.element.id) { index, thumb in
                        // The count of what is not shown rides on the last cell rather than
                        // floating beside the strip as a chip of its own.
                        if overflow > 0, index == thumbs.count - 1 {
                            overflowCell(thumb)
                        } else {
                            cell(thumb)
                        }
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
        // A photograph with no edge is pasted onto the card; with one it is placed in it.
        // Matters most in dark mode, where a bright image has nothing to sit against and
        // floats free of the surface it is supposed to belong to.
        .overlay {
            if !thumbs.isEmpty {
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(Brand.edge, lineWidth: 1)
            }
        }
    }

    /// A lone photo can afford to be a photo; a band of them only has to be recognisable.
    ///
    /// A journal list has two jobs that pull against each other - show enough of a day to
    /// recognise it, and show enough days to scan. The media-first version had let the first
    /// eat the second: three entries filled a screen, and finding last Tuesday meant scrolling
    /// rather than looking. Anyone who wants the gallery has the density toggle.
    private var height: CGFloat {
        thumbs.count == 1 ? 88 : 72
    }

    private func cell(_ thumb: DraftSummary.Thumb) -> some View {
        CollageTile(thumb: thumb, fileStore: fileStore)
    }

    /// The last cell counts what is not shown, rather than a chip floating beside the strip.
    private func overflowCell(_ thumb: DraftSummary.Thumb) -> some View {
        CollageTile(thumb: thumb, fileStore: fileStore)
            .overlay {
                Rectangle().fill(.black.opacity(0.55))
                Text("+\(overflow)")
                    .font(Type.label(17, .bold))
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
