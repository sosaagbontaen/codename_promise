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
    /// Who is still waiting on each in-flight load, one token per request. A load whose
    /// waiters have all gone (their cells scrolled away and cancelled) is skipped when its
    /// turn comes, rather than decoding a photo nobody will see.
    private var waiters: [String: Set<UUID>] = [:]

    /// Decodes running at once. A fast fling through a photo-heavy grid used to start one
    /// detached decode per tile it passed, dozens at a time, all competing with the tiles
    /// actually on screen. Four keeps the cores busy without burying the visible ones.
    private static let maxConcurrentDecodes = 4
    private var running = 0
    /// Loads waiting for a slot. Served newest first: the most recent requests are the
    /// tiles on screen now, not the ones a scroll already carried past.
    private var queue: [CheckedContinuation<Void, Never>] = []

    private init() {
        // Generous enough for a long list, bounded so a year of entries can't grow forever.
        // The count alone didn't bound memory: four hundred cover-sized images is a lot more
        // than four hundred list thumbnails, so the bytes are capped too.
        cache.countLimit = 400
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func cached(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// A thumbnail already in memory, without waiting. Lets a cell that is built for a photo
    /// seen a moment ago draw it in its first frame, instead of flashing empty first.
    func cached(id: UUID, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: Self.key(id, maxPixel) as NSString)
    }

    private static func key(_ id: UUID, _ maxPixel: CGFloat) -> String {
        "\(id.uuidString)-\(Int(maxPixel))"
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
        await thumbnail(
            id: id, url: fileStore.url(for: relativePath), isVideo: isVideo, maxPixel: maxPixel
        )
    }

    /// The same thing for a file that is not in the media store yet — a photo staged by an
    /// import and still waiting to be confirmed.
    func thumbnail(
        id: UUID,
        url: URL,
        isVideo: Bool,
        maxPixel: CGFloat = 240
    ) async -> UIImage? {
        let key = Self.key(id, maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if Task.isCancelled { return nil }

        let token = UUID()
        waiters[key, default: []].insert(token)
        let task: Task<UIImage?, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            task = Task {
                let image = await self.decode(key: key, url: url, isVideo: isVideo, maxPixel: maxPixel)
                self.inFlight[key] = nil
                self.waiters[key] = nil
                if let image { self.cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image)) }
                return image
            }
            inFlight[key] = task
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // The cell went away. It still gets whatever the load produces, but if it was the
            // last one waiting and the decode hasn't started, the decode doesn't happen.
            Task { @MainActor in self.waiters[key]?.remove(token) }
        }
    }

    /// Waits for a decode slot, then decodes, unless everyone who asked has since gone.
    private func decode(key: String, url: URL, isVideo: Bool, maxPixel: CGFloat) async -> UIImage? {
        await acquireSlot()
        defer { releaseSlot() }
        guard let wanted = waiters[key], !wanted.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            // Made once, then kept on disk: reading back a small saved thumbnail is a few
            // milliseconds, where decoding a 2048-pixel original is tens of them. Without this
            // every launch decoded every photo scrolled past again, which is what left a
            // freshly imported journal blank for a minute.
            if let saved = Self.saved(key) { return saved }
            let image = isVideo
                ? await Self.videoFrame(url, maxPixel: maxPixel)
                : Self.downsample(url, maxPixel: maxPixel)
            if let image { Self.save(image, key: key) }
            return image
        }.value
    }

    // MARK: - On disk

    /// Thumbnails kept between launches, in Caches: iOS may clear it when space runs low, and
    /// then they're made again as needed. Keyed by attachment id and size; an attachment's
    /// bytes never change under its id, so a saved thumbnail never goes stale.
    private nonisolated static let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private nonisolated static func file(_ key: String) -> URL? {
        folder?.appendingPathComponent(key + ".jpg")
    }

    private nonisolated static func saved(_ key: String) -> UIImage? {
        guard let url = file(key), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    private nonisolated static func save(_ image: UIImage, key: String) {
        guard let url = file(key), let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Makes and saves thumbnails ahead of time, quietly, so the journal draws straight from
    /// disk. Run after an import: thousands of new photos otherwise wait to be decoded until
    /// somebody scrolls to them.
    nonisolated static func prepare(_ items: [(id: UUID, url: URL, isVideo: Bool)], maxPixel: CGFloat) async {
        for item in items {
            if Task.isCancelled { return }
            let key = "\(item.id.uuidString)-\(Int(maxPixel))"
            guard let target = file(key), !FileManager.default.fileExists(atPath: target.path) else { continue }
            let image = item.isVideo ? await videoFrame(item.url, maxPixel: maxPixel) : downsample(item.url, maxPixel: maxPixel)
            if let image { save(image, key: key) }
        }
    }

    private func acquireSlot() async {
        if running < Self.maxConcurrentDecodes {
            running += 1
            return
        }
        // The slot is handed over by `releaseSlot`, already counted.
        await withCheckedContinuation { queue.append($0) }
    }

    private func releaseSlot() {
        if let next = queue.popLast() {
            next.resume()
        } else {
            running -= 1
        }
    }

    /// What an image costs the cache: its decoded bytes, not its file size.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
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
