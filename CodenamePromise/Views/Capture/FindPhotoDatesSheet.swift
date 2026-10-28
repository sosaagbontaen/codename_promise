import CodenamePromiseCore
import SwiftUI

/// Finds the real dates of an entry's photos in the Photos library and moves each one to the
/// day it was taken.
///
/// For the entry that collects things that arrived without a date: a share of Mac screenshots,
/// say, all filed together because none of them said when they were from. Nothing moves until
/// the results have been shown, and anything that couldn't be matched stays where it is.
struct FindPhotoDatesSheet: View {
    let draft: EntryDraft
    let store: DraftStore
    let fileStore: MediaFileStore
    /// Called after the emptied entry is moved to Recently Deleted, so the screen behind can close.
    var onEntryDeleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case starting
        case noAccess
        case searching(done: Int, total: Int)
        case found([UUID: Date], total: Int)
        case moved(photos: Int, days: Int, entryIsEmpty: Bool)
    }
    @State private var phase = Phase.starting

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Find photo dates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .task { await search() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .starting:
            ProgressView()
        case .noAccess:
            ContentUnavailableView {
                Label("Photos access is off", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("DumpNotes finds each photo's date by looking for the same photo in your library. Turn on access in Settings to use this.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .searching(let done, let total):
            VStack(spacing: 14) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(maxWidth: 240)
                Text("Looking in your Photos library: \(done) of \(total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .found(let dates, let total):
            results(dates, total: total)
        case .moved(let photos, let days, let entryIsEmpty):
            done(photos: photos, days: days, entryIsEmpty: entryIsEmpty)
        }
    }

    // MARK: - Results

    private func results(_ dates: [UUID: Date], total: Int) -> some View {
        let groups = Self.byDay(dates)
        let here = draft.entryDate
        let moving = groups.filter { $0.day != here }
        let movingCount = moving.reduce(0) { $0 + $1.ids.count }
        let missing = total - dates.count
        return List {
            Section {
                Text(dates.isEmpty
                     ? "None of these were found in your Photos library."
                     : "Found dates for \(dates.count) of \(total).")
                    .font(.headline)
                if missing > 0 && !dates.isEmpty {
                    Text("\(missing) weren\u{2019}t found in your library, so they stay in this entry.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !groups.isEmpty {
                Section("Taken on") {
                    ForEach(groups, id: \.day) { group in
                        HStack {
                            Text(group.day.representativeDate().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            Spacer()
                            Text(group.day == here ? "already here" : "\(group.ids.count) \(group.ids.count == 1 ? "item" : "items")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if movingCount > 0 {
                Section {
                    Button {
                        move(moving)
                    } label: {
                        Text("Move \(movingCount) to their days")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Each goes into that day\u{2019}s latest entry, or a new one if the day has none. Nothing is copied or deleted.")
                }
            }
        }
    }

    private func done(photos: Int, days: Int, entryIsEmpty: Bool) -> some View {
        List {
            Section {
                Text("Moved \(photos) \(photos == 1 ? "item" : "items") to \(days) \(days == 1 ? "day" : "days").")
                    .font(.headline)
            }
            if entryIsEmpty {
                Section {
                    Button("Delete this empty entry", role: .destructive) {
                        try? store.moveToTrash(draft)
                        dismiss()
                        onEntryDeleted()
                    }
                } footer: {
                    Text("It goes to Recently Deleted for 30 days.")
                }
            }
        }
    }

    // MARK: - Work

    private func search() async {
        let items = draft.orderedMedia.map {
            PhotoDateFinder.Item(id: $0.id, url: fileStore.url(for: $0.relativePath), isVideo: $0.kind == .video)
        }
        guard await PhotoDateFinder.requestAccess() else {
            phase = .noAccess
            return
        }
        phase = .searching(done: 0, total: items.count)
        let total = items.count
        let dates = await PhotoDateFinder.dates(for: items) { done in
            await MainActor.run { phase = .searching(done: done, total: total) }
        }
        phase = .found(dates, total: total)
    }

    private func move(_ groups: [(day: CalendarDay, ids: Set<UUID>)]) {
        let prefix = TitleSuggestion.prefix(from: (try? store.allDrafts())?.compactMap(\.content.title) ?? [])
        var photos = 0
        for group in groups {
            do {
                let existing = try store.drafts(on: group.day)
                    .filter { $0.id != draft.id }
                    .max { $0.updatedAt < $1.updatedAt }
                let destination: EntryDraft
                if let existing {
                    destination = existing
                } else {
                    // Named the way the rest of the journal is, "WWWT 10/21/26".
                    destination = try store.createDraft(entryDate: group.day)
                    try store.updateTitle(TitleSuggestion.title(prefix: prefix, day: group.day), for: destination)
                }
                photos += try store.moveMedia(ids: group.ids, from: draft, to: destination)
            } catch {
                continue
            }
        }
        let emptied = draft.content.isEmpty && draft.media.isEmpty && draft.audioCaptures.isEmpty
        phase = .moved(photos: photos, days: groups.count, entryIsEmpty: emptied)
    }

    /// Newest day first.
    private static func byDay(_ dates: [UUID: Date]) -> [(day: CalendarDay, ids: Set<UUID>)] {
        Dictionary(grouping: dates.keys) { CalendarDay(date: dates[$0]!) }
            .map { (day: $0.key, ids: Set($0.value)) }
            .sorted { $0.day > $1.day }
    }
}
