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
///
/// **This is a view onto the import, not the import itself.** The work and its state live in
/// `ImportCoordinator`, for the life of the app, and are written to disk as they happen. That
/// is what lets a five hundred photo import survive the phone locking, the app being left,
/// or the process being reclaimed: this screen can disappear at any moment and the import is
/// still there to come back to.
struct PhotoImportView: View {
    let imports: ImportCoordinator
    let store: DraftStore

    @Environment(\.dismiss) private var dismiss

    @State private var selections: [PhotosPickerItem] = []
    /// A second picker, used from the review screen. Separate from `selections` so that
    /// adding more photos appends to what is already staged instead of replacing it.
    @State private var moreSelections: [PhotosPickerItem] = []
    /// Whichever group or item is currently choosing an entry from the whole journal.
    @State private var choosing: ChooserTarget?
    @State private var confirmingCancel = false

    private var session: ImportSession? { imports.session }

    var body: some View {
        NavigationStack {
            Group {
                if let applying = imports.applying {
                    progressView(
                        "Adding to your entries",
                        done: applying.done, total: applying.total,
                        detail: "Keep the app open if you can. If you leave, it carries on from where it stopped."
                    )
                } else if session == nil {
                    pickingView
                } else if let staging = imports.staging, session?.items.isEmpty ?? true {
                    progressView(
                        "Reading dates",
                        done: staging.done, total: staging.total,
                        detail: "The screen stays on while this runs. Everything read so far is kept if you leave."
                    )
                } else {
                    reviewView
                }
            }
            .navigationTitle("Import photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing the sheet is not cancelling. Cancel says so and asks, because it
                    // throws away five hundred photos' worth of reading.
                    if session == nil {
                        Button("Close") { dismiss() }
                    } else {
                        Button("Cancel", role: .destructive) { confirmingCancel = true }
                            .disabled(imports.applying != nil)
                    }
                }
                if let session, session.phase == .reviewing, imports.applying == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        // "Import", not "Add": there is an "Add more photos" row further
                        // down, and two buttons both saying add is a coin toss.
                        Button("Import") { imports.confirm() }
                            .disabled(nothingToImport || imports.staging != nil)
                    }
                }
            }
            .confirmationDialog(
                "Cancel this import?", isPresented: $confirmingCancel, titleVisibility: .visible
            ) {
                Button("Cancel import", role: .destructive) {
                    imports.discard()
                    dismiss()
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("The photos read so far are discarded. Nothing already in your journal changes.")
            }
        }
        .onChange(of: selections) { _, items in
            guard !items.isEmpty else { return }
            imports.begin(with: items)
            selections = []
        }
        .onChange(of: moreSelections) { _, items in
            guard !items.isEmpty else { return }
            imports.add(items)
            // Cleared so picking the same photo again later still registers a change.
            moreSelections = []
        }
        .sheet(item: $choosing) { target in
            EntryChooser(store: store) { chosen in
                switch target {
                case .group(let id): imports.setDestination(.existingDraft(chosen), forGroup: id)
                case .item(let id): imports.setDestination(.existingDraft(chosen), forItem: id)
                }
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

    private func progressView(_ title: String, done: Int, total: Int, detail: String) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(maxWidth: 240)
            Text("\(title): \(done) of \(total)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var reviewView: some View {
        List {
            if let notice = imports.notice {
                Section {
                    Label(notice, systemImage: "arrow.clockwise.circle")
                        .font(.footnote)
                }
            }
            if let session {
                Section {
                    Text(summary(of: session))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let staging = imports.staging {
                        // Still reading, and already reviewable: the first photos are usable
                        // long before the five-hundredth arrives.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Still reading: \(staging.done) of \(staging.total)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ForEach(groups) { group in
                Section {
                    thumbnails(for: group)
                    destinationPicker(for: group)

                    // Only when a new entry is actually being made — otherwise this is a
                    // field that does nothing, which is worse than no field. Checked across
                    // the items too, since one pinned photo can be the only thing creating
                    // the entry this title would name.
                    if makesNewEntry(group) {
                        TextField(
                            "Title for this entry (optional)",
                            text: titleBinding(for: group)
                        )
                        .textInputAutocapitalization(.sentences)
                    }
                } header: {
                    Text(header(for: group))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if group.isUndated {
                            Text("These files carry no date, like a screenshot or an image another app re-saved. Choose where they go.")
                        }
                        // A menu on a thumbnail is invisible until somebody happens to press
                        // one, and nobody presses a thumbnail expecting a menu.
                        Text("Tap a photo to send just that one somewhere else.")
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
                .disabled(imports.staging != nil)
            }
        }
    }

    private func summary(of session: ImportSession) -> String {
        let days = session.groups.count
        let count = session.items.count
        return "\(count) \(count == 1 ? "item" : "items") across \(days) \(days == 1 ? "day" : "days")."
    }

    private func thumbnails(for group: MediaDayGrouping.Group) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(items(in: group)) { item in
                    Menu {
                        itemMenu(for: item, in: group)
                    } label: {
                        StagedThumbnail(
                            item: item,
                            url: imports.url(for: item),
                            pinned: session?.itemDestinations[item.id] != nil
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 60)
    }

    /// Where this one photo goes, independently of the rest of its day.
    @ViewBuilder
    private func itemMenu(for item: ImportSession.Item, in group: MediaDayGrouping.Group) -> some View {
        if session?.itemDestinations[item.id] != nil {
            Button {
                imports.setDestination(nil, forItem: item.id)
            } label: {
                Label("Follow this day\u{2019}s choice", systemImage: "arrow.uturn.backward")
            }
            Divider()
        }

        ForEach(existingDrafts(for: group.day), id: \.id) { draft in
            Button(label(for: draft, in: group)) {
                imports.setDestination(.existingDraft(draft.id), forItem: item.id)
            }
        }

        Button {
            choosing = .item(item.id)
        } label: {
            Label("Another entry\u{2026}", systemImage: "tray.and.arrow.down")
        }

        Button {
            imports.setDestination(.newDraft, forItem: item.id)
        } label: {
            Label(group.isUndated ? "New entry (today)" : "New entry", systemImage: "plus")
        }

        Button(role: .destructive) {
            imports.setDestination(.skip, forItem: item.id)
        } label: {
            Label("Skip this one", systemImage: "xmark")
        }
    }

    /// Whether this day will create a new entry, whether because the day says so or because
    /// a single photo in it was pinned to one.
    private func makesNewEntry(_ group: MediaDayGrouping.Group) -> Bool {
        items(in: group).contains { destination(for: $0, in: group) == .newDraft }
    }

    /// Where an item actually ends up: its own choice if it has one, otherwise its day's.
    private func destination(
        for item: ImportSession.Item, in group: MediaDayGrouping.Group
    ) -> ImportDestination {
        session?.destination(
            for: item, in: group, existingDrafts: existingDrafts(for: group.day).map(\.id)
        ) ?? .skip
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
            choosing = .group(group.id)
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

    /// True when every single item, day choice and pin included, resolves to skip.
    ///
    /// Checked per item rather than per day: one photo pinned to an entry is a reason to
    /// enable the button even if every day around it is being skipped.
    private var nothingToImport: Bool {
        groups.allSatisfy { group in
            items(in: group).allSatisfy { destination(for: $0, in: group) == .skip }
        }
    }

    // MARK: - Grouping

    private var groups: [MediaDayGrouping.Group] { session?.groups ?? [] }

    private func items(in group: MediaDayGrouping.Group) -> [ImportSession.Item] {
        session?.items(in: group) ?? []
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
            get: { session?.newEntryTitles[group.id] ?? "" },
            set: { imports.setTitle($0, forGroup: group.id) }
        )
    }

    private func binding(for group: MediaDayGrouping.Group) -> Binding<ImportDestination> {
        Binding(
            get: {
                session?.groupDestination(
                    for: group, existingDrafts: existingDrafts(for: group.day).map(\.id)
                ) ?? .newDraft
            },
            set: { imports.setDestination($0, forGroup: group.id) }
        )
    }
}

/// A staged photo, drawn from its file at the size it is shown.
///
/// Made on demand rather than held. The old import kept a decoded thumbnail for every photo
/// in memory for the whole review — five hundred of them is a quarter of a gigabyte, which
/// is precisely the kind of footprint that gets a backgrounded app reclaimed first.
private struct StagedThumbnail: View {
    let item: ImportSession.Item
    let url: URL?
    let pinned: Bool

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            guard let url else { return }
            image = await ThumbnailCache.shared.thumbnail(
                id: item.id, url: url, isVideo: item.kind == .video, maxPixel: 168
            )
        }
        // Says which photos have been pulled out of the day's choice. Without it the list
        // looks identical whether one item is going somewhere else or not, and the only way
        // to find out is to open every thumbnail in turn.
        .overlay {
            if pinned {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Brand.violet, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Brand.violet, in: Circle())
                    .offset(x: 4, y: -4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
                    .padding(3)
            }
        }
    }
}

/// What is currently picking an entry: a whole day, or one photo out of it.
private enum ChooserTarget: Identifiable {
    case group(String)
    case item(UUID)

    var id: String {
        switch self {
        case .group(let value): "group:\(value)"
        case .item(let value): "item:\(value.uuidString)"
        }
    }
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
