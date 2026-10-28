import CodenamePromiseCore
import SwiftUI

/// Settings page for filling the journal in from the Photos library. Looks first, says what
/// it found, and copies only when asked.
struct FillFromPhotosView: View {
    let filler: PhotoBackfillCoordinator
    @Environment(AppServices.self) private var services
    @State private var viewing: ViewingAdded?

    private struct ViewingAdded: Identifiable {
        let items: [MediaItem]
        let id: UUID
    }

    var body: some View {
        List {
            switch filler.phase {
            case .idle:
                if let last = filler.interrupted {
                    stoppedSummary(last, unplanned: true)
                    addedPreview(last)
                }
                Section {
                    Button {
                        Task { await filler.scan() }
                    } label: {
                        Label("Look through my Photos", systemImage: "photo.on.rectangle.angled")
                    }
                } footer: {
                    Text("Every photo and video goes into the entry for the day it was taken. A day with photos and no entry gets one. Nothing is copied until you've seen what was found.")
                }
                copiesNote

            case .noAccess:
                Section {
                    Label("Photos access is off", systemImage: "lock")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } footer: {
                    Text("DumpNotes needs to read your library to fill your journal in from it. It never changes or deletes anything there.")
                }

            case .scanning:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(filler.scanNote + "\u{2026}")
                    }
                }

            case .ready(let summary) where summary.days == 0:
                Section {
                    Label("Nothing new since last time", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.reached)
                    row("Already in your journal", summary.alreadyIn)
                    if summary.leftOut > 0 { row("Similar shots you left out", summary.leftOut) }
                    Button("Done") { filler.reset() }
                }

            case .ready(let summary):
                Section {
                    row("Photos", summary.photos)
                    row("Videos", summary.videos)
                    row("Days", summary.days)
                    row("Days that already have an entry", summary.daysWithEntries)
                    row("New entries for days without one", summary.days - summary.daysWithEntries)
                    if summary.alreadyIn > 0 {
                        row("Already in your journal", summary.alreadyIn)
                    }
                    if summary.leftOut > 0 {
                        row("Similar shots you left out before", summary.leftOut)
                    }
                } header: {
                    Text("Found")
                } footer: {
                    Text("Photos that are the same picture as one an entry already has are recognised and left out as it goes.")
                }
                Section {
                    Picker("Similar shots", selection: Binding(
                        get: { filler.similarRule },
                        set: { rule in
                            filler.similarRule = rule
                            // Looking for similar shots only happens when one of each is
                            // wanted, so switching to it looks again.
                            if rule == .keepOne { Task { await filler.scan() } }
                        }
                    )) {
                        ForEach(PhotoBackfillCoordinator.SimilarRule.allCases) { Text($0.label).tag($0) }
                    }
                    if filler.similarRule == .keepOne && summary.similarGroups > 0 {
                        NavigationLink {
                            SimilarShotsView(filler: filler)
                        } label: {
                            Label(similarLabel(summary), systemImage: "square.stack.3d.down.right")
                        }
                    }
                } footer: {
                    Text(filler.similarRule == .keepAll
                         ? "Every photo comes in, including runs of near-identical shots taken seconds apart."
                         : "Of each run of near-identical shots taken seconds apart, one comes in: your favourite, or the first. Review them to choose differently. The rest stay in your library.")
                }
                if summary.days > 0 {
                    Section {
                        Button {
                            filler.start()
                        } label: {
                            Text(fillLabel(summary.days))
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("You can leave the app while it works. Its progress shows on the Lock Screen, and if it's stopped it picks up where it left off.")
                    }
                }
                copiesNote

            case .working(let done, let total, let day):
                if let last = filler.interrupted {
                    Section {
                        Label("Picked up where the last fill stopped", systemImage: "arrow.clockwise.circle.fill")
                            .foregroundStyle(Brand.waiting)
                        row("Saved before it stopped", last.added)
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text(countLabel(done, total))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if filler.alreadyIn > 0 {
                            Text("\(filler.alreadyIn.formatted()) were already in your journal from before, so they're skipped.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(dayLabel(day))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Stop", role: .destructive) { filler.stop() }
                } footer: {
                    Text("You can leave the app. It keeps going, with its progress on the Lock Screen. Stop finishes the few in hand and saves them; everything saved stays.")
                }

            case .done(let outcome) where outcome.stopped:
                stoppedSummary(outcome, unplanned: false)
                notCopiedYet(outcome)
                addedPreview(outcome)
                Section {
                    Button("Done") { filler.reset() }
                }

            case .done(let outcome):
                Section {
                    Label(doneLabel(outcome.added), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.reached)
                    if outcome.newEntries > 0 { row("New entries", outcome.newEntries) }
                    if let last = filler.interrupted {
                        // This run finished one that had been cut off.
                        row("Saved before the earlier stop", last.added)
                    }
                    if outcome.duplicates > 0 { row("Already in an entry, left out", outcome.duplicates) }
                    Button("Done") { filler.reset() }
                }
                notCopiedYet(outcome)
                addedPreview(outcome)

            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.failed)
                    Button("Try again") { filler.reset() }
                }
            }
        }
        .fullScreenCover(item: $viewing) { viewing in
            if let files = services.files {
                MediaViewer(items: viewing.items, fileStore: files, selection: viewing.id)
            }
        }
        .navigationTitle("Fill in from Photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func similarLabel(_ summary: PhotoBackfillCoordinator.Summary) -> String {
        let noun = summary.similarGroups == 1 ? "run" : "runs"
        return "Review \(summary.similarGroups.formatted()) \(noun) (\(summary.similarPhotos.formatted()) photos)"
    }

    /// The photos and videos a fill added, newest first, to look at straight away. Tap one
    /// to see it full screen and swipe through the rest.
    @ViewBuilder
    private func addedPreview(_ outcome: PhotoBackfillCoordinator.Outcome) -> some View {
        let items = filler.added(by: outcome)
        if !items.isEmpty, let files = services.files {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 3)], spacing: 3) {
                    ForEach(items, id: \.id) { item in
                        Button {
                            viewing = ViewingAdded(items: items, id: item.id)
                        } label: {
                            PhotoTile(
                                thumb: DraftSummary.Thumb(id: item.id, relativePath: item.relativePath, isVideo: item.kind == .video),
                                fileStore: files, maxPixel: 216
                            )
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(items.count < outcome.added ? "Latest \(items.count) added" : "Added")
            }
        }
    }

    /// What a fill that stopped partway saved, and what's left.
    private func stoppedSummary(_ outcome: PhotoBackfillCoordinator.Outcome, unplanned: Bool) -> some View {
        Section {
            Label(unplanned ? "The last fill stopped partway" : "Stopped", systemImage: "pause.circle.fill")
                .foregroundStyle(Brand.waiting)
            row("Saved to your journal", outcome.added)
            if outcome.newEntries > 0 { row("New entries", outcome.newEntries) }
            if outcome.duplicates > 0 { row("Already in an entry, left out", outcome.duplicates) }
            if outcome.remaining > 0 { row("Still to fill in", outcome.remaining) }
            if let reason = outcome.pausedReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if let day = outcome.reachedDay.flatMap(CalendarDay.init(rawValue:)) {
                HStack {
                    Text("Filled in up to")
                    Spacer()
                    Text(dayLabel(day)).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Everything listed as saved is in your journal. Filling in again skips it and carries on with the rest.")
        }
    }

    /// Items a fill tried and couldn't copy, and why. None is lost: only copies are
    /// recorded, so the next fill tries each of them again.
    @ViewBuilder
    private func notCopiedYet(_ outcome: PhotoBackfillCoordinator.Outcome) -> some View {
        let total = outcome.timedOut + outcome.unavailable + outcome.unreadable
        if total > 0 {
            Section {
                row("Not copied yet", total)
                if outcome.timedOut > 0 { row("Took too long to download from iCloud", outcome.timedOut) }
                if outcome.unavailable > 0 { row("Photos didn't hand them over", outcome.unavailable) }
                if outcome.unreadable > 0 { row("Couldn't be converted", outcome.unreadable) }
                Button("Fill in again") {
                    filler.reset()
                    Task { await filler.scan() }
                }
                .fontWeight(.semibold)
            } footer: {
                Text("These are still in your Photos library and nothing is lost. Filling in again tries each one again and skips everything already copied. It goes best plugged in, on Wi-Fi, with DumpNotes open.")
            }
        }
    }

    private func fillLabel(_ days: Int) -> String {
        let noun = days == 1 ? "day" : "days"
        return "Fill in \(days.formatted()) \(noun)"
    }

    private func doneLabel(_ added: Int) -> String {
        if added == 0 { return "Nothing new to add" }
        return "Added \(added.formatted()) photos and videos"
    }

    private func dayLabel(_ day: CalendarDay) -> String {
        day.representativeDate().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    private func countLabel(_ done: Int, _ total: Int) -> String {
        "Copied \(done.formatted()) of \(total.formatted())"
    }

    private var copiesNote: some View {
        Section {
        } footer: {
            Text("DumpNotes keeps its own phone-friendly copies: photos at 2048 pixels with when and where they were taken, videos at 1080p. Your library isn't changed. Running this again later adds only what's new.")
        }
    }

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
