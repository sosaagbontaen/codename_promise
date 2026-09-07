import CodenamePromiseCore
import SwiftUI

/// The home screen, and the whole product in one control.
///
/// Everything else in the app is secondary to this: press it, talk for as long as you like,
/// press it again, and a few seconds later there is a journal entry that groups what belongs
/// together. The screen is deliberately close to empty. A person opening this app has
/// something they want to say, and every additional control is one more thing standing
/// between them and saying it.
///
/// The staging tray this replaced asked a different question. It was built around collecting
/// several things and sending them somewhere, which made sense when the destination was the
/// point. The destination is not the point any more.
struct RecordView: View {
    @Environment(AppServices.self) private var services
    /// Handed the finished entry so the shell can open it.
    let onFinished: (UUID) -> Void

    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .idle
    /// Set as soon as the audio is on disk, so the escape hatch below has somewhere to go
    /// even while the rest of the work is still running.
    @State private var draftId: UUID?
    /// Chunks safely registered this session, so an empty recording can be told from a
    /// real one without asking the database.
    @State private var chunkCount = 0

    /// What is happening, in the order it happens.
    ///
    /// Split out rather than derived from the recorder because most of these states occur
    /// after the recorder is finished with, and because the difference between "your words
    /// are safe" and "we are still working on them" is the single most important thing this
    /// screen communicates.
    enum Phase: Equatable {
        case idle
        case recording
        /// Writing the bytes to the container. Brief, and the moment the promise is kept.
        case saving
        case transcribing
        case arranging
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .saving, .transcribing, .arranging: true
            default: false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            readout
            Spacer()
            recordButton
                .padding(.bottom, 28)
            footnote
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.ground)
        .animation(.easeOut(duration: 0.22), value: phase)
    }

    // MARK: - The middle of the screen

    /// One thing at a time. At rest this is an invitation, while recording it is the clock
    /// and the meter, and afterwards it is a plain account of what is being done.
    @ViewBuilder
    private var readout: some View {
        switch phase {
        case .idle:
            VStack(spacing: 10) {
                Text("What happened today?")
                    .font(Type.title(26))
                    .foregroundStyle(Brand.ink)
                // Says what the app will do with it, because the transformation is the
                // reason to press the button and it is not visible until afterwards.
                Text("Talk for as long as you like. Jump around.\nIt gets sorted out after.")
                    .font(Type.body(15))
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }
            .transition(.opacity)

        case .recording:
            VStack(spacing: 22) {
                Text(Self.clock(recorder.elapsed))
                    .font(Type.mono(46))
                    .monospacedDigit()
                    .foregroundStyle(Brand.ink)
                    .contentTransition(.numericText())
                LiveWaveform(levels: recorder.levels, tint: Brand.Mode.voice)
                    .frame(height: 54)
                    .padding(.horizontal, 44)
            }
            .transition(.opacity)

        case .saving, .transcribing, .arranging:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(busyLabel)
                    .font(Type.body(16))
                    .foregroundStyle(Brand.ink)
                // The guarantee, and only once it is true. While the recorder is running
                // the bytes are still in a temporary file, so claiming safety a moment
                // earlier would be claiming something the app cannot yet honour.
                if phase != .saving {
                    Label("Saved on this phone", systemImage: "checkmark.circle.fill")
                        .font(Type.caption(13))
                        .foregroundStyle(Brand.reached)
                }
            }
            .transition(.opacity)

        case .failed(let why):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Brand.failed)
                Text(why)
                    .font(Type.body(15))
                    .foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                // A failure after the audio landed is a failure of the extras, never of the
                // recording. Saying so is the difference between a scare and an inconvenience.
                if draftId != nil {
                    Text("Your recording is safe.")
                        .font(Type.caption(13))
                        .foregroundStyle(Brand.reached)
                }
            }
            .transition(.opacity)
        }
    }

    private var busyLabel: String {
        switch phase {
        case .saving: "Saving what you said"
        case .transcribing: "Writing it down"
        case .arranging: "Grouping what goes together"
        default: ""
        }
    }

    // MARK: - The button

    private var recordButton: some View {
        Button {
            toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Brand.failed : Brand.Mode.voice)
                    .frame(width: 92, height: 92)
                    .shadow(
                        color: (recorder.isRecording ? Brand.failed : Brand.Mode.voice)
                            .opacity(0.35),
                        radius: 18, y: 6
                    )
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: recorder.isRecording ? 30 : 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.pressable)
        // Disabled only while the app is finishing the last one. Everything else on this
        // screen is reachable at any time.
        .disabled(phase.isBusy)
        .opacity(phase.isBusy ? 0.4 : 1)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    /// The one line of small print, and it changes rather than the row disappearing.
    @ViewBuilder
    private var footnote: some View {
        switch phase {
        case .recording:
            Text("Tap to finish")
                .font(Type.caption(12.5))
                .foregroundStyle(Brand.muted)
        case .failed:
            // The way out of a failed run, without losing the entry that was made.
            if let draftId {
                Button("Open the entry anyway") { onFinished(draftId) }
                    .font(Type.caption(13, .semibold))
            } else {
                Color.clear.frame(height: 16)
            }
        default:
            Color.clear.frame(height: 16)
        }
    }

    // MARK: - Actions

    private func toggle() {
        if recorder.isRecording {
            finish()
        } else {
            begin()
        }
    }

    /// The entry exists before the first sentence does.
    ///
    /// The draft is created here rather than at stop because chunks need somewhere to land
    /// while the person is still talking. That is also the honest shape for this app: press
    /// record and there is already an entry, so there is no window in which the recording is
    /// real but nothing in the database knows about it.
    private func begin() {
        guard let store = services.store, let files = services.files else {
            phase = .failed("The journal is not ready yet. Try again in a moment.")
            return
        }
        do {
            let draft = try store.createDraft(entryDate: .today())
            let id = draft.id
            draftId = id
            chunkCount = 0

            recorder.reserveChunk = {
                try files.reserve(preferredName: "dictation", extension: "m4a")
            }
            // Registered the moment the chunk closes. Until this runs the bytes are an
            // orphan, so it does the least possible work and does it synchronously.
            recorder.onChunkFinished = { file, duration in
                guard let draft = try? store.draft(id: id) else { return }
                try? store.attachAudioCapture(
                    id: file.id,
                    relativePath: file.relativePath,
                    sizeBytes: files.sizeBytes(of: file.relativePath) ?? 0,
                    durationSeconds: duration,
                    to: draft
                )
                chunkCount += 1
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .recording
        Task { await recorder.start() }
    }

    /// Stop, make the words durable, then try to make them useful.
    ///
    /// The order is the point and it is ADR-002 in one function. Everything after the
    /// `attachAudioCapture` call is allowed to fail; none of it can take the recording with
    /// it, and a failure at any later step leaves an entry that is already openable.
    private func finish() {
        guard let id = draftId, let store = services.store else {
            phase = .failed("The journal is not ready yet. Try again in a moment.")
            return
        }

        phase = .saving
        // Every chunk, including the last, has already been written and registered by the
        // handler set up in `begin`. There is nothing left to persist here, which is the
        // whole point: by the time this line runs the words were already safe.
        let total = recorder.stop()

        guard total != nil, chunkCount > 0 else {
            // Nothing usable. Throw away the draft rather than leaving an empty entry behind
            // for every accidental tap.
            if let draft = try? store.draft(id: id) {
                try? store.delete(draft, fileStore: services.files)
            }
            draftId = nil
            phase = .failed("That recording came back empty. Nothing was saved.")
            return
        }

        Haptics.landed()

        Task {
            phase = .transcribing
            await services.drainTranscriptions()

            phase = .arranging
            // Organising needs the transcript. If it never arrived the entry still opens,
            // holding recordings that are queued and will be picked up later.
            if services.organising?.canOrganise(draftId: id) == true {
                _ = await services.organising?.organise(draftId: id)
            }

            phase = .idle
            onFinished(id)
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
