import AVFoundation
import Foundation
import OSLog

/// Transcoding fails in many environment-specific ways — no HEVC encoder, an unreadable
/// track, a writer that won't accept settings. Each was an indistinguishable `return nil`.
private let log = Logger(subsystem: "com.codenamepromise.journal", category: "transcode")

/// Re-encodes a video to hit a size budget.
///
/// **Why not an export preset.** `AVAssetExportSession` presets target a *quality level*, not
/// a file size — `PresetLowQuality` produces whatever it produces, which for a long clip is
/// still far over budget and for a short one wastes quality it could have kept. The fix isn't
/// a cleverer codec; it's arithmetic. Bits available is a fixed number, so derive the bitrate
/// from it and encode to that.
///
/// **Why HEVC.** Roughly 40% fewer bits than H.264 for the same perceived quality, which at a
/// tight budget is the single biggest lever available. Falls back to H.264 otherwise.
///
/// **Where the wall is, honestly.** 5 MiB is about 40 megabits. A 30-second clip gets ~1.3
/// Mbps, which looks decent at 720p. Five minutes gets ~130 kbps, which no codec makes look
/// good — information theory, not a lack of cleverness. So resolution and frame rate step
/// down with the budget, and past a point the right answer is to say so.
enum VideoTranscoder {

    struct Budget {
        let bytes: Int
        /// Kept low and mono: speech survives it, and every bit here is a bit the picture
        /// doesn't get.
        var audioBitrate: Int = 48_000
    }

    static func transcode(source: URL, budget: Budget) async -> URL? {
        let asset = AVURLAsset(url: source)

        // Everything the encoder needs is loaded asynchronously up front.
        //
        // The previous version reached for `asset.tracks(withMediaType:)` and
        // `track.preferredTransform` synchronously. Those are deprecated precisely because
        // they raise when the property hasn't loaded yet — which is exactly the case for a
        // video straight out of the camera roll. The compiler warned; I shipped past it, and
        // it crashed the app on selection.
        guard
            let duration = try? await asset.load(.duration),
            duration.seconds > 0,
            let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await videoTrack.load(.naturalSize),
            let transform = try? await videoTrack.load(.preferredTransform)
        else {
            log.error("could not load asset properties")
            return nil
        }

        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        let seconds = duration.seconds
        // 5% headroom: encoders overshoot their average target and containers add overhead.
        let totalBits = Double(budget.bytes) * 8 * 0.95
        let audioBits = audioTrack == nil ? 0 : Double(budget.audioBitrate) * seconds
        let videoBitrate = Int(max((totalBits - audioBits) / seconds, 120_000))
        let target = targetSize(for: videoBitrate, natural: naturalSize)
        let frameRate = videoBitrate < 400_000 ? 24 : 30

        return await encode(
            asset: asset,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            transform: transform,
            size: target,
            videoBitrate: videoBitrate,
            audioBitrate: budget.audioBitrate,
            frameRate: frameRate
        )
    }

    /// Resolution has to match the bitrate. Encoding 1080p at 300 kbps spends every bit on
    /// blocking artefacts; the same bits at 480p look fine.
    private static func targetSize(for bitrate: Int, natural: CGSize) -> CGSize {
        let longest: CGFloat
        switch bitrate {
        case 2_500_000...: longest = 1920
        case 1_200_000...: longest = 1280
        case 600_000...: longest = 960
        case 300_000...: longest = 640
        default: longest = 480
        }

        let currentLongest = max(natural.width, natural.height)
        guard currentLongest > longest, currentLongest > 0 else { return natural }

        let ratio = longest / currentLongest
        // Even dimensions: chroma subsampling requires it.
        return CGSize(
            width: max((natural.width * ratio / 2).rounded() * 2, 2),
            height: max((natural.height * ratio / 2).rounded() * 2, 2)
        )
    }

    private static func encode(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        transform: CGAffineTransform,
        size: CGSize,
        videoBitrate: Int,
        audioBitrate: Int,
        frameRate: Int
    ) async -> URL? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcode-\(UUID().uuidString).mp4")

        func settings(for codec: AVVideoCodecType) -> [String: Any] {
            [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitrate,
                    AVVideoExpectedSourceFrameRateKey: frameRate,
                    AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                ],
            ]
        }
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: audioBitrate,
        ]

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4)
        else { return nil }

        // The fallback this comment used to promise but not implement. HEVC is preferred —
        // ~40% fewer bits for the same quality — but it isn't available everywhere, notably
        // in the simulator, where hardcoding it made every transcode fail silently and leave
        // the oversized original to be rejected by Notion.
        let videoSettings: [String: Any]
        if writer.canApply(outputSettings: settings(for: .hevc), forMediaType: .video) {
            videoSettings = settings(for: .hevc)
        } else {
            videoSettings = settings(for: .h264)
        }

        // Decode straight to the encoder's native colour space and to the target size.
        //
        // Two bugs lived here. Frames were decoded as 32BGRA and appended to a video input —
        // encoders take YUV, so every append failed. And the target size was only ever handed
        // to the *writer*: full-resolution frames were then appended to a smaller input, which
        // fails for any clip whose budget calls for scaling down. Asking the reader for the
        // size means one place decides it.
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform  // keeps portrait footage upright

        guard reader.canAdd(videoOutput) else {
            log.error("reader rejected the video output")
            return nil
        }
        guard writer.canAdd(videoInput) else {
            log.error("writer rejected video settings")
            return nil
        }
        reader.add(videoOutput)
        writer.add(videoInput)

        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(
                track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out)
                writer.add(input)
                audioPair = (out, input)
            }
        }

        guard reader.startReading() else {
            log.error("startReading failed: \(reader.error?.localizedDescription ?? "?")")
            return nil
        }
        guard writer.startWriting() else {
            log.error("startWriting failed: \(writer.error?.localizedDescription ?? "?")")
            return nil
        }
        log.info("encoding \(Int(size.width))x\(Int(size.height)) @ \(videoBitrate)bps")
        writer.startSession(atSourceTime: .zero)

        // Both tracks are drained from one scope on one queue.
        //
        // A TaskGroup would be the natural shape, but `AVAssetWriterInput` and
        // `AVAssetReaderTrackOutput` aren't `Sendable`, so Swift 6 refuses to let them into
        // child tasks — correctly: they'd be driven concurrently from two isolation domains.
        // Draining one track fully before the other isn't an option either, since the reader
        // stalls when a track's buffers go unconsumed.
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let queue = DispatchQueue(label: "transcode")
            let pending = PendingInputs(count: audioPair == nil ? 1 : 2)

            func drain(_ output: AVAssetReaderTrackOutput, _ input: AVAssetWriterInput) {
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard !pending.hasFinished(input.mediaType.rawValue) else { return }

                        if let buffer = output.copyNextSampleBuffer() {
                            if input.append(buffer) { continue }
                        }
                        // Out of samples, or the writer rejected one. Either way this track
                        // is done. `requestMediaDataWhenReady` can re-enter after
                        // `markAsFinished`, so finishing is guarded — the previous version
                        // called `leave()` on a dispatch group each time, which traps.
                        guard pending.finish(input.mediaType.rawValue) else { return }
                        input.markAsFinished()

                        if pending.allDone {
                            writer.finishWriting {
                                let ok = writer.status == .completed
                                if !ok {
                                    let w = writer.error?.localizedDescription ?? "none"
                                    let r = reader.error?.localizedDescription ?? "none"
                                    log.error("writer failed status=\(writer.status.rawValue) err=\(w) readerStatus=\(reader.status.rawValue) readerErr=\(r)")
                                }
                                continuation.resume(returning: ok ? output_url : nil)
                            }
                        }
                        return
                    }
                }
            }

            let output_url = output
            drain(videoOutput, videoInput)
            if let audioPair { drain(audioPair.0, audioPair.1) }
        }
    }
}

/// Tracks which writer inputs have finished, so completion fires exactly once.
///
/// `requestMediaDataWhenReady` blocks run on an arbitrary queue and can re-enter after the
/// input is marked finished, so this has to be atomic. Resuming a continuation twice traps,
/// as does over-leaving a dispatch group — the bug this replaces.
private final class PendingInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var finished = Set<String>()

    init(count: Int) { self.remaining = count }

    func hasFinished(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return finished.contains(key)
    }

    /// Returns true exactly once per key, for whichever caller won the race.
    func finish(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished.contains(key) else { return false }
        finished.insert(key)
        remaining -= 1
        return true
    }

    var allDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return remaining <= 0
    }
}

