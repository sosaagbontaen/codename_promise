import Foundation
import Testing

@testable import CodenamePromiseCore

/// The arithmetic that decides whether a video survives.
///
/// The behaviour under test is a product decision, not an implementation detail: a long video
/// must not be silently dropped. Before this existed, anything over about three and a half
/// minutes was re-encoded, found to still be over the cap, and abandoned — the entry synced
/// without it and nothing said which one went missing.
@Suite("Fitting a video to a per-file cap")
struct VideoPlanTests {

    private let limits = VideoPlanner.Limits()
    private let cap = VideoPlanner.Limits().bytesPerFile

    /// Estimated bytes of one part, so the assertions are about files rather than bitrates.
    private func bytes(_ encoding: VideoEncoding, seconds: Double) -> Double {
        Double(encoding.videoBitrate + encoding.audioBitrate) * seconds / 8
    }

    @Test("a video already under the cap is left alone")
    func smallVideoUntouched() {
        let plan = VideoPlanner.plan(
            durationSeconds: 12, originalBytes: 2_000_000, limits: limits
        )
        #expect(plan == .asIs)
    }

    @Test("a four-minute video is kept, in parts, instead of being given up on")
    func theCaseThatUsedToBeDropped() throws {
        // 240 seconds is past the point where one file at any watchable bitrate is possible.
        // The old path encoded it, measured it, found it over budget and returned nothing.
        let plan = VideoPlanner.plan(
            durationSeconds: 240, originalBytes: 200 * 1_000_000, limits: limits
        )

        guard case .split(let segments, let encoding) = plan else {
            Issue.record("expected a split, got \(plan)")
            return
        }
        #expect(segments.count > 1)
        #expect(segments.count <= limits.maxParts)
        // Still worth watching: well clear of the floor.
        #expect(encoding.videoBitrate > VideoPlanner.floorBitrate)
    }

    @Test("every part fits the cap")
    func partsFitTheBudget() {
        for seconds in [30.0, 90.0, 240.0, 600.0, 900.0] {
            let plan = VideoPlanner.plan(
                durationSeconds: seconds, originalBytes: 300 * 1_000_000, limits: limits
            )
            switch plan {
            case .single(let encoding):
                #expect(bytes(encoding, seconds: seconds) <= Double(cap))
            case .split(let segments, let encoding):
                for segment in segments {
                    #expect(bytes(encoding, seconds: segment.duration) <= Double(cap))
                }
            case .asIs, .tooLong:
                Issue.record("\(seconds)s should have produced an encode plan, got \(plan)")
            }
        }
    }

    @Test("the parts cover the whole clip, with no gap and nothing cut off the end")
    func segmentsTileTheClip() throws {
        let duration = 431.5
        let plan = VideoPlanner.plan(
            durationSeconds: duration, originalBytes: 500 * 1_000_000, limits: limits
        )
        guard case .split(let segments, _) = plan else {
            Issue.record("expected a split, got \(plan)")
            return
        }

        #expect(segments.first?.start == 0)
        for (previous, next) in zip(segments, segments.dropFirst()) {
            #expect(abs((previous.start + previous.duration) - next.start) < 0.001)
        }
        let end = try #require(segments.last).start + (try #require(segments.last).duration)
        #expect(abs(end - duration) < 0.001)
    }

    /// The reason to split rather than only to shrink.
    @Test("splitting buys quality back rather than only making things fit")
    func splittingRaisesQuality() throws {
        let duration = 120.0
        let plan = VideoPlanner.plan(
            durationSeconds: duration, originalBytes: 200 * 1_000_000, limits: limits
        )
        guard case .split(let segments, let encoding) = plan else {
            Issue.record("expected a split, got \(plan)")
            return
        }

        // What one file would have had to settle for: the entire budget spread over the whole
        // clip, which is below the floor and is why this splits at all. Each part gets the
        // budget to itself, so the picture is better by roughly the number of parts.
        let asOneFile = limits.usableBitsPerFile / duration - Double(limits.audioBitrate)
        #expect(asOneFile < Double(VideoPlanner.floorBitrate))
        #expect(Double(encoding.videoBitrate) > asOneFile * Double(segments.count) * 0.9)
    }

    /// Splitting is the last resort, not the first move.
    @Test("a clip that fits in one file stays one file")
    func staysWholeWhenItCan() throws {
        let plan = VideoPlanner.plan(
            durationSeconds: 30, originalBytes: 180 * 1_000_000, limits: limits
        )
        guard case .single(let encoding) = plan else {
            Issue.record("30 seconds should stay one file, got \(plan)")
            return
        }
        // And it spends the whole budget rather than a preset's idea of "medium".
        let wholeBudget = limits.usableBitsPerFile / 30 - Double(limits.audioBitrate)
        #expect(Double(encoding.videoBitrate) > wholeBudget * 0.95)
    }

    @Test("the number of parts is the fewest that clears the floor")
    func fewestParts() throws {
        let duration = 240.0
        let plan = VideoPlanner.plan(
            durationSeconds: duration, originalBytes: 200 * 1_000_000, limits: limits
        )
        guard case .split(let segments, _) = plan else {
            Issue.record("expected a split, got \(plan)")
            return
        }
        // One fewer part would have put the picture under the floor, which is what makes this
        // the fewest rather than merely a working number.
        let oneFewer = limits.usableBitsPerFile / (duration / Double(segments.count - 1))
            - Double(limits.audioBitrate)
        #expect(oneFewer < Double(VideoPlanner.floorBitrate))
    }

    @Test("never re-encodes above the bitrate the source already had")
    func doesNotInventDetail() throws {
        // Five minutes of already-low-bitrate footage. Encoding it at 1.2 Mbps would make a
        // bigger file than the original and add nothing to it.
        let plan = VideoPlanner.plan(
            durationSeconds: 300,
            originalBytes: 15 * 1_000_000,
            sourceBitrate: 400_000,
            limits: limits
        )
        let encoding: VideoEncoding
        var partCount = 1
        switch plan {
        case .single(let e): encoding = e
        case .split(let segments, let e): encoding = e; partCount = segments.count
        default:
            Issue.record("expected an encode plan, got \(plan)")
            return
        }
        #expect(encoding.videoBitrate <= 400_000)
        // And having clamped the bitrate, it must not still cut the clip into the many parts
        // a higher bitrate would have needed.
        #expect(partCount <= 5)
    }

    @Test("past the point where parts stop being reasonable, it says so rather than pretending")
    func tooLongIsNamed() throws {
        let plan = VideoPlanner.plan(
            durationSeconds: 45 * 60, originalBytes: 2_000 * 1_000_000, limits: limits
        )
        guard case .tooLong(let seconds, let wouldNeed) = plan else {
            Issue.record("expected tooLong, got \(plan)")
            return
        }
        #expect(seconds == 45 * 60)
        #expect(wouldNeed > limits.maxParts)
    }

    @Test("the boundary between kept and too long is where the part limit is")
    func theBoundaryIsThePartLimit() {
        // Just inside: eighteen minutes still plans.
        let inside = VideoPlanner.plan(
            durationSeconds: 17 * 60, originalBytes: 900 * 1_000_000, limits: limits
        )
        if case .tooLong = inside { Issue.record("17 minutes should still be kept") }

        // A generous limit moves the boundary rather than changing the shape of the answer,
        // which is what makes this a setting rather than a hard wall.
        let generous = VideoPlanner.Limits(maxParts: 40)
        let stillKept = VideoPlanner.plan(
            durationSeconds: 45 * 60, originalBytes: 2_000 * 1_000_000, limits: generous
        )
        if case .tooLong = stillKept { Issue.record("40 parts should cover 45 minutes") }
    }

    @Test("a zero-length or unreadable duration does not divide by zero")
    func degenerateDuration() {
        #expect(VideoPlanner.plan(durationSeconds: 0, originalBytes: 99_000_000) == .asIs)
        #expect(VideoPlanner.plan(durationSeconds: -3, originalBytes: 99_000_000) == .asIs)
    }
}

/// The helpers the encoder calls directly when it has to fall back.
@Suite("Dividing a clip into parts")
struct VideoSegmentTests {

    @Test("segments cover the clip exactly")
    func segmentsCoverTheClip() throws {
        let segments = VideoPlanner.segments(count: 3, over: 100)
        #expect(segments.count == 3)
        #expect(segments[0].start == 0)
        let end = try #require(segments.last).start + (try #require(segments.last).duration)
        #expect(abs(end - 100) < 0.0001)
    }

    @Test("one part is the whole clip")
    func onePart() {
        let segments = VideoPlanner.segments(count: 1, over: 42)
        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].duration == 42)
    }

    /// The fallback after an encode overshoots: cut it in two, and each half has room.
    @Test("halving a clip roughly doubles the bitrate each half can hold")
    func halvingDoublesTheBudget() {
        let whole = VideoPlanner.bitrate(forParts: 1, over: 60, sourceBitrate: 20_000_000)
        let half = VideoPlanner.bitrate(forParts: 2, over: 60, sourceBitrate: 20_000_000)
        #expect(Double(half) > Double(whole) * 1.9)
    }

    @Test("the source bitrate still caps what a part is encoded at")
    func sourceCapsTheParts() {
        #expect(VideoPlanner.bitrate(forParts: 2, over: 60, sourceBitrate: 300_000) == 300_000)
    }

    @Test("a bitrate is never zero or negative, however the clip is divided")
    func neverDegenerate() {
        for parts in 1...12 {
            for seconds in [1.0, 60.0, 3_600.0] {
                #expect(
                    VideoPlanner.bitrate(
                        forParts: parts, over: seconds, sourceBitrate: 8_000_000
                    ) > 0
                )
            }
        }
    }
}
