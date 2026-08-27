import AVFoundation
import CodenamePromiseCore
import ImageIO
import UIKit

/// Downsampled thumbnails, cached.
///
/// The draft list wants half a dozen thumbnails per row and the editor wants a strip of them,
/// so this is on a scrolling hot path. Loading a 4 MB JPEG with `UIImage(contentsOfFile:)` to
/// draw it at 80 points — which is what the editor did — decodes the entire full-resolution
/// image into memory for every thumbnail, every time it scrolls past. `ImageIO` can decode
/// straight to the size actually needed instead.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        // Generous enough for a long list, bounded so a year of entries can't grow forever.
        cache.countLimit = 400
    }

    func cached(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// Loads a thumbnail, reusing an in-flight load for the same key so a fast scroll doesn't
    /// start the same decode several times.
    func thumbnail(
        for item: MediaItem,
        fileStore: MediaFileStore,
        maxPixel: CGFloat = 240
    ) async -> UIImage? {
        await thumbnail(
            id: item.id, relativePath: item.relativePath, isVideo: item.kind == .video,
            fileStore: fileStore, maxPixel: maxPixel
        )
    }

    /// The same thing from plain values.
    ///
    /// The draft list renders from snapshots rather than from `@Model` objects, because a row
    /// that outlives its model — which happens on delete, while the row animates away — traps
    /// the moment it reads an attribute. A thumbnail request must not be the thing that drags
    /// a model back into the view layer.
    func thumbnail(
        id: UUID,
        relativePath: String,
        isVideo: Bool,
        fileStore: MediaFileStore,
        maxPixel: CGFloat = 240
    ) async -> UIImage? {
        let key = "\(id.uuidString)-\(Int(maxPixel))"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let existing = inFlight[key] { return await existing.value }

        let url = fileStore.url(for: relativePath)

        let task = Task<UIImage?, Never> {
            let image: UIImage? = await Task.detached(priority: .utility) {
                isVideo
                    ? await Self.videoFrame(url, maxPixel: maxPixel)
                    : Self.downsample(url, maxPixel: maxPixel)
            }.value
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// Decodes at the size needed rather than decoding fully and shrinking afterwards.
    private nonisolated static func downsample(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private nonisolated static func videoFrame(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // A moment in rather than frame zero: the first frame of a phone video is often black
        // while exposure settles.
        let time = CMTime(seconds: 0.3, preferredTimescale: 60)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
