import CodenamePromiseCore
import SwiftUI

/// Settings page for filling the journal in from the Photos library. Looks first, says what
/// it found, and copies only when asked.
struct FillFromPhotosView: View {
    let filler: PhotoBackfillCoordinator

    var body: some View {
        List {
            switch filler.phase {
            case .idle:
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
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text(countLabel(done, total))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(dayLabel(day))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("You can leave the app. It keeps going, with its progress on the Lock Screen.")
                }

            case .done(let outcome):
                Section {
                    Label(doneLabel(outcome.added), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.reached)
                    if outcome.newEntries > 0 { row("New entries", outcome.newEntries) }
                    if outcome.duplicates > 0 { row("Already in an entry, left out", outcome.duplicates) }
                    if outcome.unreadable > 0 { row("Couldn't be read", outcome.unreadable) }
                    Button("Done") { filler.reset() }
                }

            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.failed)
                    Button("Try again") { filler.reset() }
                }
            }
        }
        .navigationTitle("Fill in from Photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func similarLabel(_ summary: PhotoBackfillCoordinator.Summary) -> String {
        let noun = summary.similarGroups == 1 ? "run" : "runs"
        return "Review \(summary.similarGroups.formatted()) \(noun) (\(summary.similarPhotos.formatted()) photos)"
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
        "\(done.formatted()) of \(total.formatted())"
    }

    private var copiesNote: some View {
        Section {
        } footer: {
            Text("DumpNotes keeps its own phone-friendly copies: photos at 2048 pixels with their date and place kept, videos at 1080p. Your library isn't changed. Running this again later adds only what's new.")
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
