import CodenamePromiseCore
import PhotosUI
import SwiftUI

/// Thirty seconds of journaling: a note, some photos, which day they belong to, done.
///
/// The same day-by-day shape as the Mac panel and the share sheet. Photos sort into the day
/// they were taken as they're added, each day gets its own note and entry, and a note can be
/// written for any other day. It writes a capture into the app's own inbox and files it from
/// there, so it goes through exactly the path the others do, including the digest.
struct QuickDumpView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// Set when the sheet was opened for a particular day, such as a gap in the day strip.
    var initialDay: CalendarDay? = nil
    /// The other ways in, for when thirty seconds isn't what this is.
    var onWriteFullEntry: () -> Void = {}
    var onImportPhotos: () -> Void = {}

    private struct Item: Identifiable {
        let id: UUID
        let url: URL
        let kind: Capture.Kind
    }

    @State private var plan = CapturePlan()
    @State private var items: [UUID: Item] = [:]
    @State private var picks: [PhotosPickerItem] = []
    @State private var picking = false
    /// The day whose "Add photos" was tapped.
    @State private var pickingFor: UUID?
    @State private var importingAudio = false
    @State private var choosingDateFor: UUID?
    @State private var reading = 0
    @State private var problem: String?
    @State private var saving = false
    @State private var confirmingDiscard = false
    @FocusState private var focusedDay: UUID?

    /// Dot-prefixed so the inbox scan never takes it for a capture.
    @State private var staging = CaptureInbox.appInbox
        .appendingPathComponent(".staging/\(UUID().uuidString)", isDirectory: true)

    /// Read once when the sheet opens. It was a computed property, so every keystroke in
    /// the note redrew the sheet and re-read the whole journal to build it.
    @State private var index: EntryIndex?

    var body: some View {
        NavigationStack {
            Form {
                // The first day is the dump. Everything else is optional and folded away, so
                // opening this is a text box with a few quiet rows under it, not a form.
                ForEach(Array(plan.days.enumerated()), id: \.element.id) { index, day in
                    daySections(day, isFirst: index == 0)
                }

                Section {
                    DisclosureGroup("More options") {
                        Button {
                            let earliest = plan.days.map(\.day).min() ?? .today()
                            let id = plan.addDay(earliest.adding(days: -1))
                            focusedDay = id
                        } label: {
                            row("Add another day", systemImage: "calendar.badge.plus")
                        }
                    }
                    .tint(Brand.ink)
                }

                if let problem {
                    Section {
                        Text(problem).font(.footnote).foregroundStyle(Brand.failed)
                    }
                }

                // Shown only before anything's been added, so they can't throw work away.
                if plan.isEmpty {
                    Section {
                        Button(action: onWriteFullEntry) {
                            row("Write a full entry", systemImage: "square.and.pencil",
                                detail: "Open a blank page for more space.")
                        }
                        Button(action: onImportPhotos) {
                            row("Import photos", systemImage: "photo.stack",
                                detail: "Add lots of photos at once.")
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Dump")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if plan.isEmpty { discard() } else { confirmingDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { add() }
                        .buttonStyle(.borderedProminent)
                        .disabled(plan.isEmpty || reading > 0 || saving)
                }
            }
            .confirmationDialog("Discard this?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { discard() }
                Button("Keep editing", role: .cancel) {}
            }
            .photosPicker(isPresented: $picking, selection: $picks, matching: .any(of: [.images, .videos]))
            .sheet(item: Binding(
                get: { choosingDateFor.map(DayRef.init) },
                set: { choosingDateFor = $0?.id }
            )) { ref in
                NavigationStack {
                    DatePicker(
                        "Day",
                        selection: Binding(
                            get: { plan[ref.id]?.day.representativeDate() ?? Date() },
                            set: { date in
                                plan[ref.id]?.day = CalendarDay(date: date)
                                // An entry picked on the old day doesn't belong to the new one.
                                if case .existing = plan[ref.id]?.entry { plan[ref.id]?.entry = .latest }
                            }
                        ),
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("Which day?")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { choosingDateFor = nil }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, let target = pickingFor else { return }
                loadAudio(urls, into: target)
            }
            .onChange(of: picks) { _, picked in
                guard !picked.isEmpty, let target = pickingFor else { return }
                picks = []
                load(picked, into: target)
            }
            .task {
                try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                if index == nil, let store = services.store { index = try? EntryIndex.make(from: store) }
                if let initialDay, let first = plan.days.first, plan.isEmpty {
                    plan[first.id]?.day = initialDay
                }
                focusedDay = plan.days.first?.id
            }
        }
        .tint(Brand.violet)
        .interactiveDismissDisabled(!plan.isEmpty)
    }

    // MARK: - A day

    /// A row with a violet icon and neutral text: the accent marks it as tappable without
    /// every option on the screen shouting in purple.
    private func row(_ title: String, systemImage: String, value: String? = nil, detail: String? = nil, chevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Brand.violet)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Brand.ink)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Brand.muted)
                }
            }
            Spacer(minLength: 4)
            if let value {
                Text(value).foregroundStyle(Brand.muted)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.muted.opacity(0.6))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func daySections(_ day: CapturePlan.Day, isFirst: Bool) -> some View {
        Section {
            TextField(
                isFirst ? "What\u{2019}s on your mind?" : "A note about this day",
                text: Binding(get: { plan[day.id]?.text ?? "" }, set: { plan[day.id]?.text = $0 }),
                axis: .vertical
            )
            .font(Type.journal(17))
            .lineLimit(isFirst ? 5...14 : 3...12)
            .focused($focusedDay, equals: day.id)
            .padding(.vertical, 4)

            if !day.fileIds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(day.fileIds, id: \.self) { fileId in
                            if let item = items[fileId] {
                                StagedTile(id: item.id, url: item.url, kind: item.kind)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            remove(fileId)
                                        } label: {
                                            Label("Leave this one out", systemImage: "xmark")
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 64)
            }

            // Media for this day, right where the day is.
            Menu {
                Button {
                    pickingFor = day.id
                    picking = true
                } label: {
                    Label("Photos and videos", systemImage: "photo.on.rectangle.angled")
                }
                Button {
                    pickingFor = day.id
                    importingAudio = true
                } label: {
                    Label("Audio from Files", systemImage: "waveform")
                }
            } label: {
                HStack {
                    row(day.fileIds.isEmpty ? "Add media" : "Add more media", systemImage: "photo.badge.plus",
                        chevron: !(reading > 0 && pickingFor == day.id))
                    if reading > 0, pickingFor == day.id {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } header: {
            if !isFirst {
                Text("Another day")
            }
        }

        Section {
            // A row and a calendar rather than the compact date picker, which formats itself
            // inconsistently ("10/26/26" beside "Oct 27, 2026") once rows are added.
            Button {
                choosingDateFor = day.id
            } label: {
                row(day.day.representativeDate().formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year()),
                    systemImage: "calendar")
            }

            let existing = index?.entries(on: day.day) ?? []
            Picker(selection: Binding(get: { day.entry.shown(among: existing) }, set: { plan[day.id]?.entry = $0 })) {
                Text("New entry").tag(CapturePlan.EntryChoice.new)
                if !existing.isEmpty {
                    Section("Existing entries") {
                        ForEach(existing) { entry in
                            Text(entry.title).tag(CapturePlan.EntryChoice.existing(entry.id))
                        }
                    }
                }
            } label: {
                Text("Entry").foregroundStyle(Brand.ink)
            }
            .pickerStyle(.menu)

            if !isFirst {
                Button("Remove this day", role: .destructive) {
                    for fileId in day.fileIds { remove(fileId) }
                    plan.removeDay(day.id)
                }
            }
        }
    }

    // MARK: - Photos

    /// Copies each pick into staging and adds it to the day it was picked for.
    private func load(_ picked: [PhotosPickerItem], into dayId: UUID) {
        reading += picked.count
        let folder = staging
        Task {
            for pick in picked {
                defer { reading -= 1 }
                let isVideo = pick.supportedContentTypes.contains { $0.conforms(to: .movie) }
                let received: URL?
                if isVideo {
                    received = (try? await pick.loadTransferable(type: PickedMovie.self))?.url
                } else {
                    received = (try? await pick.loadTransferable(type: PickedImageFile.self))?.url
                }
                guard let received else {
                    problem = "One of those couldn\u{2019}t be read, so it was left out."
                    continue
                }
                let id = UUID()
                let target = folder.appendingPathComponent("\(id.uuidString).\(received.pathExtension.lowercased())")
                do {
                    try FileManager.default.moveItem(at: received, to: target)
                } catch {
                    problem = "One of those couldn\u{2019}t be read, so it was left out."
                    continue
                }
                items[id] = Item(id: id, url: target, kind: isVideo ? .video : .photo)
                if plan[dayId] != nil {
                    plan[dayId]?.fileIds.append(id)
                } else {
                    // The day was removed while these loaded; keep them on the first day
                    // rather than dropping something somebody chose.
                    if let first = plan.days.first { plan[first.id]?.fileIds.append(id) }
                }
            }
        }
    }

    /// Audio picked in Files: copied in while access is granted, then transcribed into the
    /// entry like a recording made in the app.
    private func loadAudio(_ urls: [URL], into dayId: UUID) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
            let target = staging.appendingPathComponent("\(id.uuidString).\(ext)")
            do {
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                problem = "\(url.lastPathComponent) couldn\u{2019}t be read, so it was left out."
                continue
            }
            items[id] = Item(id: id, url: target, kind: .audio)
            if plan[dayId] != nil {
                plan[dayId]?.fileIds.append(id)
            } else if let first = plan.days.first {
                plan[first.id]?.fileIds.append(id)
            }
        }
    }

    private func remove(_ fileId: UUID) {
        if let item = items.removeValue(forKey: fileId) { try? FileManager.default.removeItem(at: item.url) }
        plan.remove(file: fileId)
    }

    // MARK: - Finishing

    private func add() {
        saving = true
        let sources = plan.days.flatMap(\.fileIds).compactMap { id in
            items[id].map { CaptureWriter.Source(url: $0.url, kind: $0.kind, move: true, id: id) }
        }
        do {
            try CaptureWriter(inbox: CaptureInbox.appInbox).write(plan: plan, sources: sources, source: "app")
            try? FileManager.default.removeItem(at: staging)
            Haptics.picked()
            dismiss()
            Task { await services.drainInbox() }
        } catch {
            saving = false
            problem = "Couldn\u{2019}t save that. Everything is still here, so you can try again."
        }
    }

    private func discard() {
        try? FileManager.default.removeItem(at: staging)
        dismiss()
    }
}

private struct DayRef: Identifiable { let id: UUID }

/// A staged photo, drawn small from its file.
private struct StagedTile: View {
    let id: UUID
    let url: URL
    let kind: Capture.Kind
    @State private var image: UIImage?

    private var isVideo: Bool { kind == .video }

    var body: some View {
        Group {
            if kind == .audio {
                Brand.violet.opacity(0.18)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Brand.violet)
                    }
            } else if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .padding(4)
                    .shadow(radius: 2)
            }
        }
        .task(id: id) {
            guard kind != .audio else { return }
            image = await ThumbnailCache.shared.thumbnail(id: id, url: url, isVideo: isVideo, maxPixel: 180)
        }
    }
}
