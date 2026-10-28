import AVFoundation
import ImageIO
import UIKit
import Vision

/// Reads a photo on the device: the words in it, and what it shows. Apple's Vision does both,
/// so nothing leaves the phone and no account or key is needed.
enum PhotoReader {
    struct Reading: Sendable {
        var words = ""
        var labels: [String] = []
        /// False when Vision failed at one of the two (it can't classify on a simulator,
        /// for one). What it did find still counts; the photo is read again later.
        var complete = true
    }

    enum Outcome: Sendable {
        case read(Reading)
        /// The file couldn't be opened, most likely not downloaded from iCloud yet.
        case unreadable
        /// Vision stalled and was cancelled.
        case timedOut
    }

    /// Long enough for a page dense with text on an older phone; a photo that takes longer
    /// has stalled rather than being slow.
    private static let timeLimit: Double = 20

    /// How sure Vision must be before a photo counts as showing something. Lower finds more
    /// and gets more wrong; this keeps "tree" to photos with a tree in them.
    private static let labelConfidence: Float = 0.3

    static func read(_ url: URL, isVideo: Bool) async -> Outcome {
        guard let image = isVideo ? await frame(of: url) : downsampled(url) else { return .unreadable }
        let text = VNRecognizeTextRequest()
        #if targetEnvironment(simulator)
        // The accurate reader needs the Neural Engine and hangs without one.
        text.recognitionLevel = .fast
        #else
        text.recognitionLevel = .accurate
        #endif
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Each request on its own, so one Vision can't run doesn't lose the other.
        let reads = await perform(text, on: handler)
        if reads == .timedOut { return .timedOut }
        let classifies = await perform(classify, on: handler)
        if classifies == .timedOut { return .timedOut }

        var reading = Reading()
        reading.complete = reads == .done && classifies == .done
        reading.words = (text.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        reading.labels = (classify.results ?? [])
            .filter { $0.confidence >= labelConfidence }
            .sorted { $0.confidence > $1.confidence }
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return .read(reading)
    }

    private enum Performed: Sendable { case done, failed, timedOut }

    /// Runs one request off the caller's thread, cancelling it if it outlasts the time limit.
    private static func perform(_ request: VNRequest, on handler: VNImageRequestHandler) async -> Performed {
        let work = VisionWork(request: request, handler: handler)
        return await withTimeLimit(seconds: timeLimit, onTimeout: .timedOut) { finish in
            DispatchQueue.global(qos: .utility).async {
                let succeeded = (try? work.handler.perform([work.request])) != nil
                finish(succeeded ? .done : .failed)
            }
            return { work.request.cancel() }
        }
    }

    /// Big enough to read small print, small enough to be quick.
    private static func downsampled(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ] as CFDictionary)
    }

    /// A video is read from one frame, a second in, past any fade from black.
    private static func frame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        if let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image {
            return image
        }
        return try? await generator.image(at: .zero).image
    }
}

/// A request and its handler, handed to the queue that performs them. Used by one thread at
/// a time: the performer, then only `cancel`, which Vision allows from anywhere.
private struct VisionWork: @unchecked Sendable {
    let request: VNRequest
    let handler: VNImageRequestHandler
}
