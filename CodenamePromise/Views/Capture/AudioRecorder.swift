import AVFoundation
import CodenamePromiseCore
import Foundation
import Observation

/// Records dictation in finished chunks, straight into durable storage.
///
/// The recorder is still deliberately dumb about drafts, transcription and the network. What
/// changed is where the bytes live while someone is talking, and that change is the point.
///
/// It used to stream into `FileManager.temporaryDirectory` and hand the whole recording over
/// only when the person pressed stop. A ten minute reflection therefore existed nowhere
/// durable for ten minutes, in a directory the system is free to purge, with no row in the
/// database that would let a relaunch know it had ever been started. A crash, a force-quit or
/// a jetsam took all of it. That was survivable while dictation was short bursts inside the
/// editor. It is not survivable now that talking for ten minutes is the product.
///
/// I checked whether a single file could just be made to survive the kill, because cutting
/// the audio up costs something and avoiding it would have been better. It cannot. An AAC
/// recording killed mid-write leaves the samples on disk but the header is written on close:
/// CAF comes back claiming zero frames, M4A will not open at all. Neither returns the audio.
///
/// So: chunks, each one closed and registered before the next begins, which is what
/// `AudioCapture.chunkIndex` was designed for. A crash costs the chunk in progress and
/// nothing else.
///
/// **Chunks end in silence wherever possible.** Cutting on a fixed timer would slice a word
/// in half every time, and the transcriber would produce two half-words for it. The level
/// meter that drives the waveform already knows when somebody has stopped talking, so after
/// `minimumChunk` the recorder waits for a pause and rotates there. `maximumChunk` is the
/// backstop for someone who never pauses.
///
/// **Pausing closes the chunk.** It would be easier to call `AVAudioRecorder.pause()` and
/// leave the file open, and it would also mean a paused recording — the state someone leaves
/// the app in precisely because they expect to come back to it — was the one state where a
/// force-quit lost everything since the last rotation. Closing the chunk instead makes every
/// paused recording fully durable, which is the whole reason to offer a pause.
///
/// **Recording survives leaving the app.** `UIBackgroundModes: audio` plus an active session
/// is what keeps the process alive while somebody checks a message. The session is therefore
/// *not* deactivated when the app goes to the background, only on stop and on pause.
@MainActor
@Observable
final class AudioRecorder {
    enum RecorderState: Equatable {
        case idle
        case denied
        case recording
        /// Mid-session, microphone released, everything recorded so far already on disk.
        case paused
        case failed(String)
    }

    private(set) var state: RecorderState = .idle
    /// Total across every chunk, so the clock on screen counts the whole session.
    private(set) var elapsed: TimeInterval = 0

    /// Recent input levels, 0...1, oldest first.
    ///
    /// Purely for the user's benefit: a timer counting up proves the app is running, not
    /// that it can hear you. Someone talking into a phone wants to see the thing react.
    private(set) var levels: [CGFloat] = []

    /// Somewhere durable to write the next chunk. Set before `start()`.
    var reserveChunk: (() throws -> ReservedFile)?

    /// What the Lock Screen calls this recording. Set before `start()`.
    var activityName: String = "your entry"

    /// A finished chunk, already closed and on disk at `file.relativePath`. The handler must
    /// register it synchronously: until it does, the bytes are an orphan that `reapOrphans`
    /// would collect.
    var onChunkFinished: ((_ file: ReservedFile, _ duration: TimeInterval) -> Void)?

    /// How much history the meter keeps. At the 60ms tick below this is a couple of seconds
    /// of speech, which is enough to read as movement without becoming a scrolling chart.
    private static let levelWindow = 34

    /// Chunk boundaries. A crash costs at most one chunk, so shorter is safer and longer is
    /// kinder to the transcriber. Forty-five seconds of exposure is small enough to lose
    /// without losing the thread of what you were saying.
    private static let minimumChunk: TimeInterval = 45
    /// The backstop for an unbroken monologue. Two and a half minutes, after which the cut
    /// happens wherever it happens.
    private static let maximumChunk: TimeInterval = 150
    /// Below this the microphone is hearing a room rather than a voice.
    private static let silenceLevel: CGFloat = 0.08
    /// Long enough to be a pause between thoughts rather than the gap between two words.
    private static let silenceToRotate: TimeInterval = 0.6

    private var recorder: AVAudioRecorder?
    private var current: ReservedFile?
    /// Built during the previous chunk so a rotation is `stop(); record()` with no file
    /// system work in between, which keeps the seam under a millisecond.
    private var standby: (recorder: AVAudioRecorder, file: ReservedFile)?
    private var ticker: Task<Void, Never>?
    private var interruptions: Task<Void, Never>?
    /// Completed chunks only. The one in progress is added when it closes.
    private var completedDuration: TimeInterval = 0
    private var silentFor: TimeInterval = 0

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }
    /// Mid-session either way: there is a recording to come back to.
    var isActive: Bool { state == .recording || state == .paused }

    /// Set when a phone call or another app took the microphone away, so the UI can say what
    /// happened rather than leave a pause nobody asked for looking like a bug.
    private(set) var interruptionNotice: String?

    // MARK: - Session

    func start() async {
        guard state != .recording else { return }
        guard await Self.requestPermission() else {
            state = .denied
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // `.default` mode, not `.spokenAudio`: that one is playback-oriented and this
            // pairing throws on a physical device. It failed silently because the UI had no
            // case for `.failed`, so the button appeared to do nothing at all.
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            completedDuration = 0
            elapsed = 0
            levels = []
            silentFor = 0

            let (recorder, file) = try makeRecorder()
            guard recorder.record() else {
                state = .failed("The recorder wouldn't start.")
                return
            }
            self.recorder = recorder
            self.current = file
            self.state = .recording
            self.interruptionNotice = nil
            startTicking()
            watchForInterruptions()
            RecordingActivity.start(entryName: activityName)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Pause

    /// Ends the chunk in progress and lets the microphone go.
    ///
    /// Everything said so far is on disk and registered before this returns, so a pause is a
    /// safe place to leave a recording — including leaving it by force-quitting the app.
    ///
    /// The session is deactivated rather than held open. Holding it would keep the orange
    /// microphone indicator lit in the status bar while the app was not, in fact, listening,
    /// which is a thing a journaling app should never do.
    func pause() {
        guard state == .recording else { return }

        ticker?.cancel()
        ticker = nil
        closeCurrentChunk()
        standby?.recorder.deleteRecording()
        standby = nil
        silentFor = 0
        levels = []

        state = .paused
        elapsed = completedDuration
        RecordingActivity.update(banked: completedDuration, isRecording: false)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    /// Picks the session back up with a fresh chunk.
    ///
    /// Can genuinely fail: another app may have taken the microphone while this one was
    /// paused. Nothing recorded is at risk either way, so the failure is reported and the
    /// recorder stays paused rather than pretending to be running.
    func resume() async {
        guard state == .paused else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let (recorder, file) = try makeRecorder()
            guard recorder.record() else {
                interruptionNotice = "Couldn\u{2019}t start recording again. What you have so far is saved."
                return
            }
            self.recorder = recorder
            self.current = file
            self.state = .recording
            self.interruptionNotice = nil
            startTicking()
            watchForInterruptions()
            RecordingActivity.update(banked: completedDuration, isRecording: true)
        } catch {
            interruptionNotice = "Couldn\u{2019}t start recording again. What you have so far is saved."
        }
    }

    /// Closes the final chunk and ends the session. The chunk is delivered through
    /// `onChunkFinished` like every other one, so there is no separate last-chunk path to
    /// get wrong. Returns the total duration, or nil if nothing usable was recorded.
    @discardableResult
    func stop() -> TimeInterval? {
        ticker?.cancel()
        ticker = nil
        interruptions?.cancel()
        interruptions = nil
        interruptionNotice = nil
        RecordingActivity.end()

        let closed = closeCurrentChunk()

        // Discard anything prepared for a chunk that will now never happen.
        standby?.recorder.deleteRecording()
        standby = nil

        state = .idle
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )

        let total = completedDuration
        completedDuration = 0
        guard closed || total > 0 else {
            state = .failed("The recording came back empty.")
            return nil
        }
        return total
    }

    // MARK: - Chunks

    private func makeRecorder() throws -> (AVAudioRecorder, ReservedFile) {
        guard let reserveChunk else {
            throw NSError(
                domain: "AudioRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nowhere to save the recording."]
            )
        }
        let file = try reserveChunk()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: file.url, settings: settings)
        recorder.isMeteringEnabled = true
        // Allocates buffers and creates the file up front, so `record()` failing means
        // something real rather than a slow first write.
        guard recorder.prepareToRecord() else {
            throw NSError(
                domain: "AudioRecorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't prepare the microphone."]
            )
        }
        return (recorder, file)
    }

    /// Stops the running chunk and hands it over. Returns whether anything was delivered.
    @discardableResult
    private func closeCurrentChunk() -> Bool {
        guard let recorder, let current else {
            self.recorder = nil
            self.current = nil
            return false
        }

        // Read the duration before stopping: `currentTime` is zero afterwards.
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.current = nil

        // A chunk with nothing in it is not worth a row. Its directory is reaped later.
        guard duration > 0.25 else { return false }

        completedDuration += duration
        onChunkFinished?(current, duration)
        return true
    }

    /// Ends this chunk and begins the next without leaving the session.
    private func rotate() {
        guard let next = standby else { return }
        standby = nil

        closeCurrentChunk()

        guard next.recorder.record() else {
            state = .failed("The recording stopped unexpectedly.")
            return
        }
        recorder = next.recorder
        current = next.file
        silentFor = 0
    }

    /// Whether the current chunk should end now.
    ///
    /// Past the maximum it ends regardless. Between the minimum and the maximum it waits for
    /// the speaker to stop, so the cut lands between thoughts rather than inside a word.
    private func shouldRotate(chunkTime: TimeInterval) -> Bool {
        if chunkTime >= Self.maximumChunk { return true }
        guard chunkTime >= Self.minimumChunk, standby != nil else { return false }
        return silentFor >= Self.silenceToRotate
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // Fast enough to look like sound rather than like a progress bar.
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.state == .recording, let recorder = self.recorder else {
                    return
                }
                let chunkTime = recorder.currentTime
                self.elapsed = self.completedDuration + chunkTime

                recorder.updateMeters()
                let level = Self.normalise(recorder.averagePower(forChannel: 0))
                self.levels.append(level)
                if self.levels.count > Self.levelWindow { self.levels.removeFirst() }

                self.silentFor = level < Self.silenceLevel ? self.silentFor + 0.06 : 0

                // Build the next recorder ahead of the seam, never at it.
                if chunkTime >= Self.minimumChunk - 3, self.standby == nil {
                    self.standby = try? self.makeRecorder()
                }
                if self.shouldRotate(chunkTime: chunkTime) {
                    self.rotate()
                }
            }
        }
    }

    // MARK: - Interruptions

    /// A phone call, Siri, or another app taking the microphone.
    ///
    /// Without this a call would stop the recording dead: iOS tears the session down, the
    /// `AVAudioRecorder` quietly stops, and the timer on screen keeps counting a recording
    /// that no longer exists. Treated as a pause, which means the chunk is closed and safe,
    /// and picked back up automatically when the system says it is allowed.
    private func watchForInterruptions() {
        guard interruptions == nil else { return }
        interruptions = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification
            )
            for await note in stream {
                guard let self else { return }
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []

                switch type {
                case .began:
                    guard self.state == .recording else { continue }
                    self.pause()
                    self.interruptionNotice =
                        "Paused \u{2014} something else needed the microphone. Everything so far is saved."
                case .ended:
                    guard self.state == .paused, options.contains(.shouldResume) else { continue }
                    await self.resume()
                default:
                    continue
                }
            }
        }
    }

    /// dBFS to something drawable.
    ///
    /// `averagePower` is decibels full scale: 0 is clipping and -160 is silence, on a scale
    /// where ordinary speech sits around -25. Mapping the whole range linearly gives a flat
    /// line that never moves, so the floor is lifted to -50 and the result curved, which is
    /// roughly how loudness is actually perceived.
    private static func normalise(_ decibels: Float) -> CGFloat {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        let clamped = max(floor, min(0, decibels))
        let linear = (clamped - floor) / -floor
        return CGFloat(pow(linear, 1.6))
    }

    private static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }
}
