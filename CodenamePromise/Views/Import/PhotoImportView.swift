import CodenamePromiseCore
import PhotosUI
import SwiftUI

/// Bulk-import a few days of photos and let the app work out which day each one belongs to.
///
/// The pain this removes: remembering which shots came from which day, then picking them out
/// one entry at a time. Apple's picker won't filter by date, and human memory is exactly what
/// was going wrong. So instead — select everything, read each file's own capture date, group
/// by day, and confirm where each day's photos should go.
///
/// Reading the date from the file rather than from PhotoKit is what keeps this from needing
/// full photo library access.
struct PhotoImportView: View {
    let store: DraftStore
    let fileStore: MediaFileStore
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selections: [PhotosPickerItem] = []
    @State private var staged: [StagedMedia] = []
    @State private var destinations: [String: ImportDestination] = [:]
    @State private var newEntryTitles: [String: String] = [:]
    /// A second picker, used from the review screen. Separate from `selections` so that
    /// adding more photos appends to what is already staged instead of replacing it.
    @State private var moreSelections: [PhotosPickerItem] = []
    /// Which group is choosing an entry from another day, by group id.
    @State private var choosingEntryFor: String?
    /// Progress while adding a second batch. Deliberately not the `phase` enum: switching
    /// phase swaps `reviewView` out of the hierarchy, and it owns the picker that is at that
    /// moment still dismissing itself. Destroying it took the whole sheet down with it.
    @State private var addingMore: (done: Int, total: Int)?
    @State private var phase: Phase = .picking
    @State private var summary: String?

    private enum Phase: Equatable {
        case picking
        case loading(done: Int, total: Int)
        case review
        case applying
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .picking: pickingView
                case .loading(let done, let total): loadingView(done: done, total: total)
                case .review: reviewView
                case .applying: ProgressView("Adding to your entries…")
                }
            }
            .navigationTitle("Import photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cleanUpAndDismiss() }
                }
                if phase == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        // "Import", not "Add": there is an "Add more photos" row further
                        // down, and two buttons both saying add is a coin toss.
                        Button("Import") { Task { await apply() } }
                            .disabled(groups.allSatisfy { destinations[$0.id] == .skip })
                    }
                }
            }
        }
        .onChange(of: selections) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        .onChange(of: moreSelections) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await load(items, appending: true)
                // Cleared so picking the same photo again later still registers a change.
                moreSelections = []
            }
        }
        .sheet(item: Binding(
            get: { choosingEntryFor.map(GroupID.init) },
            set: { choosingEntryFor = $0?.rawValue }
        )) { target in
            EntryChooser(store: store) { chosen in
                destinations[target.rawValue] = .existingDraft(chosen)
            }
        }
    }

    // MARK: - Phases

    private var pickingView: some View {
        ContentUnavailableView {
            Label("Import a few days at once", systemImage: "photo.stack")
        } description: {
            Text("Pick everything from the last few days. Each photo's own date decides which entry it belongs to, so there is nothing to remember.")
        } actions: {
            PhotosPicker(
                selection: $selections,
                maxSelectionCount: nil,
                matching: .any(of: [.images, .videos])
            ) {
                Text("Choose photos")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func loadingView(done: Int, total: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(maxWidth: 220)
            Text("Reading dates: \(done) of \(total)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var reviewView: some View {
        List {
            if let summary {
                Section { Text(summary).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(groups) { group in
                Section {
                    thumbnails(for: group)
                    destinationPicker(for: group)

                    // Only when a new entry is actually being made — otherwise this is a
                    // field that does nothing, which is worse than no field.
                    if binding(for: group).wrappedValue == .newDraft {
                        TextField(
                            "Title for this entry (optional)",
                            text: titleBinding(for: group)
                        )
                        .textInputAutocapitalization(.sentences)
                    }
                } header: {
                    Text(header(for: group))
                } footer: {
                    if group.isUndated {
                        Text("These files carry no date, like a screenshot or an image another app re-saved. Choose where they go.")
                    }
                }
            }

            // Reachable without losing what is already staged. Forgetting one photo used to
            // mean cancelling and starting the whole import again.
            Section {
                PhotosPicker(
                    selection: $moreSelections,
                    maxSelectionCount: nil,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label("Add more photos", systemImage: "plus.circle")
                }
                .disabled(addingMore != nil)

                if let addingMore {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading dates: \(addingMore.done) of \(addingMore.total)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func thumbnails(for group: MediaDayGrouping.Group) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items(in: group)) { media in
                    Group {
                        if let thumbnail = media.thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.15)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        if media.kind == .video {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.white)
                                .padding(3)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func destinationPicker(for group: MediaDayGrouping.Group) -> some View {
        Picker("Add to", selection: binding(for: group)) {
            ForEach(destinationOptions(for: group), id: \.id) { draft in
                Text(label(for: draft, in: group)).tag(ImportDestination.existingDraft(draft.id))
            }
            Text(group.isUndated ? "New entry (today)" : "New entry").tag(ImportDestination.newDraft)
            Text("Skip these").tag(ImportDestination.skip)
        }

        // The way to reach an entry on any other day.
        //
        // Without this a group could only ever go to an entry filed under its own date, and
        // undated items — screenshots, anything another app re-saved — had no date, so they
        // could only ever become a new entry for today. That is the common case, not an edge
        // case, and it made the feature useless for filling in an entry you already started.
        Button {
            choosingEntryFor = group.id
        } label: {
            Label("Add to a different entry\u{2026}", systemImage: "tray.and.arrow.down")
                .font(.subheadline)
        }
    }

    /// Entries this group may be filed under: the ones on its own day, plus whichever entry
    /// has been chosen from elsewhere.
    ///
    /// The second half is load-bearing. A `Picker` renders blank when its selection is a tag
    /// none of its options carry, so an entry chosen from another day has to be added to the
    /// list or the row silently goes empty.
    private func destinationOptions(for group: MediaDayGrouping.Group) -> [EntryDraft] {
        var options = existingDrafts(for: group.day)
        if case .existingDraft(let id) = binding(for: group).wrappedValue,
           !options.contains(where: { $0.id == id }),
           let chosen = try? store.draft(id: id) {
            options.append(chosen)
        }
        return options
    }

    // MARK: - Grouping

    private var groups: [MediaDayGrouping.Group] {
        MediaDayGrouping.group(
            staged.map { MediaDayGrouping.Item(id: $0.id, capturedAt: $0.capturedAt) }
        )
    }

    private func items(in group: MediaDayGrouping.Group) -> [StagedMedia] {
        let ids = Set(group.items.map(\.id))
        return staged.filter { ids.contains($0.id) }
    }

    private func header(for group: MediaDayGrouping.Group) -> String {
        let count = group.items.count
        let noun = count == 1 ? "item" : "items"
        guard let day = group.day else { return "No date, \(count) \(noun)" }
        let formatted = day.representativeDate()
            .formatted(.dateTime.weekday(.wide).month(.wide).day())
        return "\(formatted) \u{00B7} \(count) \(noun)"
    }

    private func existingDrafts(for day: CalendarDay?) -> [EntryDraft] {
        guard let day, let drafts = try? store.drafts(on: day) else { return [] }
        return drafts
    }

    private func label(for draft: EntryDraft, in group: MediaDayGrouping.Group? = nil) -> String {
        let name: String
        if let title = draft.content.title, !title.isEmpty {
            name = title
        } else {
            let firstLine = draft.content.rawText
                .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            name = firstLine.map { String($0.prefix(30)) } ?? "Untitled entry"
        }
        // Say which day, but only when it is not the one this group is already filed under.
        // Repeating the date the section header already shows would just be noise.
        guard let group, group.day != draft.entryDate else { return name }
        let day = draft.entryDate.representativeDate()
            .formatted(.dateTime.month(.abbreviated).day())
        return "\(name) \u{00B7} \(day)"
    }

    private func titleBinding(for group: MediaDayGrouping.Group) -> Binding<String> {
        Binding(
            get: { newEntryTitles[group.id] ?? "" },
            set: { newEntryTitles[group.id] = $0 }
        )
    }

    private func binding(for group: MediaDayGrouping.Group) -> Binding<ImportDestination> {
        Binding(
            get: { destinations[group.id] ?? defaultDestination(for: group) },
            set: { destinations[group.id] = $0 }
        )
    }

    /// One existing entry for that day is almost certainly the one you meant. Several is
    /// ambiguous, so default to a new one rather than picking arbitrarily.
    private func defaultDestination(for group: MediaDayGrouping.Group) -> ImportDestination {
        let existing = existingDrafts(for: group.day)
        return existing.count == 1 ? .existingDraft(existing[0].id) : .newDraft
    }

    // MARK: - Work

    /// - Parameter appending: true when this is a second trip to the picker, so what is
    ///   already staged is kept. Replacing it was why forgetting one photo meant starting
    ///   the whole import again.
    private func load(_ items: [PhotosPickerItem], appending: Bool = false) async {
        // Appending reports progress in place. See `addingMore` for why this must not touch
        // `phase`.
        if appending { addingMore = (0, items.count) } else { phase = .loading(done: 0, total: items.count) }
        var loaded: [StagedMedia] = []

        for (index, item) in items.enumerated() {
            if appending { addingMore = (index, items.count) } else { phase = .loading(done: index, total: items.count) }
            if let media = await stage(item) { loaded.append(media) }
        }

        staged = appending ? staged + loaded : loaded
        let days = MediaDayGrouping.group(
            staged.map { MediaDayGrouping.Item(id: $0.id, capturedAt: $0.capturedAt) }
        ).count
        summary = staged.isEmpty
            ? "Nothing could be read from those items."
            : "\(staged.count) items across \(days) days."
        addingMore = nil
        if !appending { phase = .review }
    }

    /// Copies the item somewhere stable and reads its capture date.
    ///
    /// Written to a temp file rather than held in memory: importing a week of photos at once
    /// would otherwise hold tens of megabytes of image data while the user reviews.
    private func stage(_ item: PhotosPickerItem) async -> StagedMedia? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        let id = UUID()

        if isVideo {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
                return nil
            }
            let capturedAt = await CaptureDateReader.captureDate(ofVideoAt: movie.url)
            return StagedMedia(id: id, url: movie.url, kind: .video, capturedAt: capturedAt,
                               thumbnail: nil)
        }

        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let capturedAt = CaptureDateReader.captureDate(ofImageData: data)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(id.uuidString).jpg")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }

        return StagedMedia(
            id: id, url: url, kind: .photo, capturedAt: capturedAt,
            thumbnail: UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 112, height: 112))
        )
    }

    private func apply() async {
        phase = .applying
        var added = 0
        var entries = 0

        for group in groups {
            let destination = destinations[group.id] ?? defaultDestination(for: group)
            guard destination != .skip else { continue }

            let draft: EntryDraft?
            switch destination {
            case .existingDraft(let id):
                draft = try? store.draft(id: id)
            case .newDraft:
                // An undated group has no day to file under, so it becomes today's entry —
                // the user can move it with the date picker.
                let created = try? store.createDraft(entryDate: group.day)
                if let created {
                    let title = (newEntryTitles[group.id] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        try? store.updateTitle(title, for: created)
                    }
                    entries += 1
                }
                draft = created
            case .skip:
                draft = nil
            }
            guard let draft else { continue }

            for media in items(in: group) {
                if (try? store.attachMedia(
                    from: media.url, kind: media.kind, to: draft, fileStore: fileStore
                )) != nil {
                    added += 1
                }
            }
        }

        cleanUp()
        onFinish()
        dismiss()
        _ = (added, entries)
    }

    private func cleanUp() {
        for media in staged {
            try? FileManager.default.removeItem(at: media.url)
        }
        staged = []
    }

    private func cleanUpAndDismiss() {
        cleanUp()
        dismiss()
    }
}

struct StagedMedia: Identifiable {
    let id: UUID
    let url: URL
    let kind: MediaKind
    let capturedAt: Date?
    var thumbnail: UIImage?
}

/// `sheet(item:)` needs something Identifiable, and a group id is a bare String.
private struct GroupID: Identifiable {
    let rawValue: String
    var id: String { rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Pick any entry in the journal, for photos that belong to a day other than their own.
private struct EntryChooser: View {
    let store: DraftStore
    let onChoose: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [EntryDraft] = []

    var body: some View {
        NavigationStack {
            List {
                if drafts.isEmpty {
                    ContentUnavailableView(
                        "No entries yet", systemImage: "tray",
                        description: Text("Photos will start a new entry instead.")
                    )
                }
                ForEach(drafts, id: \.id) { draft in
                    Button {
                        onChoose(draft.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name(of: draft)).font(.body)
                            Text(draft.entryDate.representativeDate()
                                .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Choose an entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { drafts = (try? store.allDrafts()) ?? [] }
        }
    }

    private func name(of draft: EntryDraft) -> String {
        if let title = draft.content.title, !title.isEmpty { return title }
        let firstLine = draft.content.rawText
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        return firstLine.map { String($0.prefix(40)) } ?? "Untitled entry"
    }
}
