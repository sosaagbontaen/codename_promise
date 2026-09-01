import AVFoundation
import Foundation
import Observation

/// Records dictation to a temporary file, then hands the bytes over for durable storage.
///
/// The recorder itself is deliberately dumb: it knows nothing about drafts, transcription, or
/// the network. Its only contract is that when recording stops, the bytes exist. The caller
/// persists them before attempting anything else. See ADR-002.
@MainActor
@Observable
final class AudioRecorder {
    enum RecorderState: Equatable {
        case idle
        case denied
        case recording
        case failed(String)
    }

    private(set) var state: RecorderState = .idle
    private(set) var elapsed: TimeInterval = 0

    /// Recent input levels, 0...1, oldest first.
    ///
    /// Purely for the user's benefit: a timer counting up proves the app is running, not
    /// that it can hear you. Someone talking into a phone wants to see the thing react.
    private(set) var levels: [CGFloat] = []

    /// How much history the meter keeps. At the 60ms tick below this is a couple of seconds
    /// of speech, which is enough to read as movement without becoming a scrolling chart.
    private static let levelWindow = 34

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var ticker: Task<Void, Never>?

    var isRecording: Bool { state == .recording }

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

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dictation-\(UUID().uuidString).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            // Allocates buffers and creates the file up front, so `record()` failing means
            // something real rather than a slow first write.
            guard recorder.prepareToRecord() else {
                state = .failed("Couldn't prepare the microphone.")
                return
            }
            guard recorder.record() else {
                state = .failed("The recorder wouldn't start.")
                return
            }

            self.recorder = recorder
            self.fileURL = url
            self.elapsed = 0
            self.levels = []
            self.state = .recording
            startTicking()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops and returns the recorded bytes. Returns nil if there was nothing usable — the
    /// caller must treat that as "no new words", never as "words were lost".
    func stop() -> (data: Data, duration: TimeInterval)? {
        ticker?.cancel()
        ticker = nil

        guard let recorder, let fileURL else {
            state = .idle
            return nil
        }

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false)

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            state = .failed("The recording came back empty.")
            return nil
        }
        // The temp file has served its purpose; the durable copy is the caller's job.
        try? FileManager.default.removeItem(at: fileURL)

        return (data, duration)
    }

    private func startTicking() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // Fast enough to look like sound rather than like a progress bar.
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.state == .recording, let recorder = self.recorder else {
                    return
                }
                self.elapsed = recorder.currentTime

                recorder.updateMeters()
                self.levels.append(Self.normalise(recorder.averagePower(forChannel: 0)))
                if self.levels.count > Self.levelWindow { self.levels.removeFirst() }
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
