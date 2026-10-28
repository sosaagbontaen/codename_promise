import AVFoundation
import CoreGraphics
import ImageIO
import Photos
import UIKit

/// Finds when a photo already in an entry was taken, by finding the same picture in the
/// person's Photos library and reading the date Photos has for it.
///
/// For files that carry no date of their own. A Mac screenshot AirDropped to the phone is the
/// usual one: the PNG holds no date, and the date Photos shows lives only in Photos' own
/// records, which a share never passes on. The copy in DumpNotes is the same picture,
/// though, so it can be found again.
///
/// Matching is strict on purpose, since a wrong date files a photo on the wrong day:
/// same pixel size first, then a small grayscale fingerprint that has to agree closely. A
/// photo that can't be matched with confidence is left alone and reported as such.
///
/// Read-only. Nothing in the Photos library is changed.
enum PhotoDateFinder {
    struct Item: Sendable {
        let id: UUID
        let url: URL
        let isVideo: Bool
    }

    /// Asks for library access if it hasn't been asked yet. True when there's something to read.
    static func requestAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status == .authorized || status == .limited
    }

    /// The date Photos has for each item it could match. Items with no confident match are
    /// absent. Runs off the main actor; `progress` is called after each item.
    static func dates(
        for items: [Item],
        progress: @escaping @Sendable (Int) async -> Void
    ) async -> [UUID: Date] {
        await Task.detached(priority: .userInitiated) {
            var found: [UUID: Date] = [:]
            // Candidates' fingerprints, kept across items: twenty screenshots the same size
            // would otherwise fingerprint the same library photos twenty times.
            var fingerprints: [String: Fingerprint] = [:]
            for (index, item) in items.enumerated() {
                let date = item.isVideo
                    ? await videoDate(item)
                    : photoDate(item, cache: &fingerprints)
                if let date { found[item.id] = date }
                await progress(index + 1)
            }
            return found
        }.value
    }

    // MARK: - Photos

    private static func photoDate(_ item: Item, cache: inout [String: Fingerprint]) -> Date? {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let mine = Fingerprint(source: source)
        else { return nil }

        let candidates = assets(type: .image, width: width, height: height)
        var scored: [(distance: Double, date: Date)] = []
        for index in 0..<candidates.count {
            let asset = candidates.object(at: index)
            guard let date = asset.creationDate else { continue }
            let key = asset.localIdentifier
            if cache[key] == nil { cache[key] = Fingerprint(asset: asset) }
            guard let theirs = cache[key] else { continue }
            scored.append((mine.distance(to: theirs), date))
        }
        scored.sort { $0.distance < $1.distance }
        // Close enough to be the same picture as Photos draws it, and clearly closer than
        // anything else, unless the runner-up is from the same day anyway (a duplicate, or
        // a burst of near-identical screenshots).
        guard let best = scored.first, best.distance < 10 else { return nil }
        if scored.count > 1 {
            let runnerUp = scored[1]
            let sameDay = Calendar.current.isDate(runnerUp.date, inSameDayAs: best.date)
            guard sameDay || runnerUp.distance - best.distance >= 3 else { return nil }
        }
        return best.date
    }

    /// Library items of this kind at this size, either way round.
    private static func assets(type: PHAssetMediaType, width: Int, height: Int) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d AND ((pixelWidth == %d AND pixelHeight == %d) OR (pixelWidth == %d AND pixelHeight == %d))",
            type.rawValue, width, height, height, width
        )
        options.includeHiddenAssets = true
        return PHAsset.fetchAssets(with: options)
    }

    // MARK: - Videos

    /// Same size and the same length to a tenth of a second, and only when exactly one
    /// library video fits: there's no cheap fingerprint for a video worth trusting more.
    private static func videoDate(_ item: Item) async -> Date? {
        let asset = AVURLAsset(url: item.url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration), duration.isNumeric
        else { return nil }
        let seconds = duration.seconds
        let candidates = assets(type: .video, width: Int(abs(size.width)), height: Int(abs(size.height)))
        var matches: [Date] = []
        candidates.enumerateObjects { asset, _, _ in
            if abs(asset.duration - seconds) < 0.1, let date = asset.creationDate { matches.append(date) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Fingerprints

    /// A 16 by 16 grayscale thumbnail. Two copies of one picture land within a few levels of
    /// each other; two different pictures, even of the same screen, rarely do.
    struct Fingerprint {
        static let side = 16
        let pixels: [UInt8]

        init?(source: CGImageSource) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            self.init(image: image)
        }

        init?(asset: PHAsset) {
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var result: CGImage?
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 128, height: 128),
                contentMode: .aspectFit, options: options
            ) { image, _ in result = image?.cgImage }
            guard let result else { return nil }
            self.init(image: result)
        }

        init?(image: CGImage) {
            let side = Self.side
            var pixels = [UInt8](repeating: 0, count: side * side)
            let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                return true
            }
            guard drew else { return nil }
            self.pixels = pixels
        }

        /// Average difference per pixel, 0 to 255.
        func distance(to other: Fingerprint) -> Double {
            var total = 0
            for (a, b) in zip(pixels, other.pixels) { total += abs(Int(a) - Int(b)) }
            return Double(total) / Double(pixels.count)
        }
    }
}
