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
                        Button("Add") { Task { await apply() } }
                            .disabled(groups.allSatisfy { destinations[$0.id] == .skip })
                    }
                }
            }
        }
        .onChange(of: selections) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
    }

    // MARK: - Phases

    private var pickingView: some View {
        ContentUnavailableView {
            Label("Import a few days at once", systemImage: "photo.stack")
        } description: {
            Text("Pick everything from the last few days. Each photo's own date decides which entry it belongs to — no need to remember.")
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
            Text("Reading dates — \(done) of \(total)")
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
                        Text("These files carry no date — a screenshot, or an image an app re-saved. Choose where they go.")
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
        let existing = existingDrafts(for: group.day)
        Picker("Add to", selection: binding(for: group)) {
            ForEach(existing, id: \.id) { draft in
                Text(label(for: draft)).tag(ImportDestination.existingDraft(draft.id))
            }
            Text(group.isUndated ? "New entry (today)" : "New entry").tag(ImportDestination.newDraft)
            Text("Skip these").tag(ImportDestination.skip)
        }
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
        guard let day = group.day else { return "No date — \(count) \(noun)" }
        let formatted = day.representativeDate()
            .formatted(.dateTime.weekday(.wide).month(.wide).day())
        return "\(formatted) — \(count) \(noun)"
    }

    private func existingDrafts(for day: CalendarDay?) -> [EntryDraft] {
        guard let day, let drafts = try? store.drafts(on: day) else { return [] }
        return drafts
    }

    private func label(for draft: EntryDraft) -> String {
        if let title = draft.content.title, !title.isEmpty { return title }
        let firstLine = draft.content.rawText
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        return firstLine.map { String($0.prefix(30)) } ?? "Untitled entry"
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

    private func load(_ items: [PhotosPickerItem]) async {
        phase = .loading(done: 0, total: items.count)
        var loaded: [StagedMedia] = []

        for (index, item) in items.enumerated() {
            phase = .loading(done: index, total: items.count)
            if let media = await stage(item) { loaded.append(media) }
        }

        staged = loaded
        summary = loaded.isEmpty
            ? "Nothing could be read from those items."
            : "\(loaded.count) items across \(MediaDayGrouping.group(loaded.map { MediaDayGrouping.Item(id: $0.id, capturedAt: $0.capturedAt) }).count) days."
        phase = .review
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
