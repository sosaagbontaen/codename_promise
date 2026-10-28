import AVFoundation
import CodenamePromiseCore
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet entry point. Hosts `ShareView` and hands it what was shared.
///
/// Nothing here touches the journal. The extension writes a capture into the App Group's inbox
/// and the app files it the next time it opens, which keeps the journal's store owned by one
/// process and means the extension can't leave it half-written if iOS ends it early.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let model = ShareModel(providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        model.start()
    }
}

/// Copies what was shared into a staging folder as soon as the sheet opens, sorting each
/// photo into the day it was taken as it goes, so that by the time someone has written their
/// notes the files are usually already there and "Add" is instant.
@MainActor
@Observable
final class ShareModel {
    static let appGroup = "group.com.codenamepromise.journal"

    struct Item: Identifiable {
        /// Also the attachment's id in the journal.
        let id: UUID
        let url: URL
        let kind: Capture.Kind
    }

    var plan = CapturePlan()
    private(set) var items: [UUID: Item] = [:]

    private(set) var total = 0
    private(set) var preparedCount = 0
    private(set) var preparing = true
    private(set) var problem: String?
    private(set) var saving = false

    let index: EntryIndex?
    private let providers: [NSItemProvider]
    private let done: () -> Void
    private let cancelled: () -> Void
    private let staging: URL?
    private var skipped = 0

    init(providers: [NSItemProvider], done: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.providers = providers
        self.done = done
        self.cancelled = cancel
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
        // Dot-prefixed so the app's inbox scan never mistakes it for a capture.
        staging = group?.appendingPathComponent("Inbox/.staging/\(UUID().uuidString)", isDirectory: true)
        index = group.flatMap { EntryIndex.read(from: $0.appendingPathComponent(EntryIndex.fileName)) }
        titlePrefix = TitleSuggestion.prefix(from: index?.entries.map(\.title) ?? [])
    }

    var hasMedia: Bool { total > 0 }

    func entries(on day: CalendarDay) -> [EntryIndex.Entry] {
        index?.entries(on: day) ?? []
    }

    var canAdd: Bool { !preparing && !saving && staging != nil && !plan.isEmpty }

    func setDay(_ date: Date, for id: UUID) {
        // An entry picked on the old day doesn't belong to the new one.
        if case .existing = plan[id]?.entry { plan[id]?.entry = .latest }
        // Joins that day if it's already here, and gives a "No date found" group its date.
        plan.setDay(CalendarDay(date: date), for: id)
    }

    /// Moves one photo or video to another day, the way a misdated one gets put right.
    func move(_ fileId: UUID, to date: Date) {
        plan.move(fileId, to: CalendarDay(date: date))
    }

    /// "WWWT 10/27/26" for this day, learned from the titles already in the journal. Nil
    /// when the day's things are going into an entry that already exists, or when an entry
    /// that day already has this title (pick that one instead).
    func suggestedTitle(for dayId: UUID) -> String? {
        guard let day = plan[dayId], !day.undated else { return nil }
        let existing = entries(on: day.day)
        if case .existing = day.entry.shown(among: existing) { return nil }
        let title = TitleSuggestion.title(prefix: titlePrefix, day: day.day)
        if existing.contains(where: { $0.title == title }) { return nil }
        return title
    }

    /// Whether the day's things are going into a new entry, which is when a title applies.
    func makesNewEntry(_ dayId: UUID) -> Bool {
        guard let day = plan[dayId] else { return false }
        if case .existing = day.entry.shown(among: entries(on: day.day)) { return false }
        return true
    }

    @ObservationIgnored private let titlePrefix: String

    func addDay() {
        // The day before the earliest one here: filling in a gap is the usual reason.
        let earliest = plan.days.map(\.day).min() ?? .today()
        plan.addDay(CalendarDay(date: earliest.representativeDate().addingTimeInterval(-86_400)))
    }

    func remove(_ fileId: UUID) {
        if let item = items.removeValue(forKey: fileId) { try? FileManager.default.removeItem(at: item.url) }
        plan.remove(file: fileId)
    }

    func removeDay(_ id: UUID) {
        for fileId in plan[id]?.fileIds ?? [] {
            if let item = items.removeValue(forKey: fileId) { try? FileManager.default.removeItem(at: item.url) }
        }
        plan.removeDay(id)
    }

    func start() {
        guard let staging else {
            preparing = false
            problem = "DumpNotes couldn\u{2019}t open its inbox. Open the app once, then try again."
            return
        }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let media = providers.filter { Self.kind(of: $0) != nil }
        total = media.count

        Task {
            var shared: [String] = []
            for provider in providers where Self.kind(of: provider) == nil {
                if let text = await Self.loadText(provider) { shared.append(text) }
            }
            if !shared.isEmpty, let first = plan.days.first {
                plan[first.id]?.text = shared.joined(separator: "\n\n")
            }
            // A few at a time. Photos hands each one over slowly (it may have to fetch the
            // original from iCloud first), so waiting on them one by one is what made a big
            // share crawl. Only a few are ever in flight, and each is a file on disk rather
            // than in memory, so the extension stays well inside its memory limit. Results
            // are placed in the order they were selected, not the order they finish.
            let width = 4
            var finished: [Int: Prepared?] = [:]
            var nextToPlace = 0
            await withTaskGroup(of: (Int, Prepared?).self) { group in
                var started = 0
                func startNext() {
                    guard started < media.count, let kind = Self.kind(of: media[started]) else { return }
                    let index = started, provider = SharedProvider(media[index])
                    started += 1
                    group.addTask { (index, await Self.prepare(provider.value, kind: kind, into: staging)) }
                }
                for _ in 0..<width { startNext() }
                for await (index, result) in group {
                    finished[index] = result
                    startNext()
                    while let ready = finished.removeValue(forKey: nextToPlace) {
                        nextToPlace += 1
                        guard let ready else { skipped += 1; continue }
                        let item = Item(id: UUID(), url: ready.url, kind: ready.kind)
                        items[item.id] = item
                        // No date means "No date found", never silently today.
                        plan.place(item.id, on: ready.taken.map { CalendarDay(date: $0) })
                        preparedCount += 1
                    }
                }
            }
            preparing = false
            if skipped > 0 {
                problem = skipped == 1
                    ? "One item couldn\u{2019}t be read and will be left out."
                    : "\(skipped) items couldn\u{2019}t be read and will be left out."
            }
        }
    }

    func add() {
        guard canAdd, let staging else { return }
        saving = true
        let inbox = staging.deletingLastPathComponent().deletingLastPathComponent()
        let sources = plan.days.flatMap(\.fileIds).compactMap { id in
            items[id].map { CaptureWriter.Source(url: $0.url, kind: $0.kind, move: true, id: id) }
        }
        do {
            try CaptureWriter(inbox: inbox).write(plan: plan, sources: sources, source: "share")
            try? FileManager.default.removeItem(at: staging)
            done()
        } catch {
            saving = false
            problem = "Couldn\u{2019}t save that. There may not be enough space on this iPhone."
        }
    }

    func cancel() {
        if let staging { try? FileManager.default.removeItem(at: staging) }
        cancelled()
    }

    // MARK: - Loading

    nonisolated private static func kind(of provider: NSItemProvider) -> Capture.Kind? {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { return .video }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return .photo }
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) { return .audio }
        return nil
    }

    nonisolated private static func type(for kind: Capture.Kind) -> UTType {
        switch kind {
        case .video: .movie
        case .photo: .image
        case .audio: .audio
        case .text: .plainText
        }
    }

    /// NSItemProvider is safe to load from any thread (its callbacks arrive on arbitrary
    /// queues by design) but isn't marked Sendable, so it crosses into the loading tasks
    /// in this box. Each provider is only ever used by the one task it's handed to.
    struct SharedProvider: @unchecked Sendable {
        let value: NSItemProvider
        init(_ value: NSItemProvider) { self.value = value }
    }

    struct Prepared: Sendable {
        let url: URL
        let kind: Capture.Kind
        let taken: Date?
    }

    /// Brings one shared item into the staging folder and reads the day it was taken.
    nonisolated private static func prepare(_ provider: NSItemProvider, kind: Capture.Kind, into folder: URL) async -> Prepared? {
        guard let (url, lentName) = await copy(provider, kind: kind, into: folder) else { return nil }
        var taken: Date? = kind == .video
            ? await CaptureDateReader.captureDate(ofVideoAt: url)
            : CaptureDateReader.captureDate(ofImageAt: url)
        // A Mac screenshot holds no date inside; its name does. Photos usually passes the
        // original name along, either as the suggested name or as the lent file's own.
        if taken == nil {
            taken = [provider.suggestedName, lentName].compactMap { $0 }
                .lazy.compactMap { CaptureDateReader.captureDate(fromFileName: $0) }.first
        }
        return Prepared(url: url, kind: kind, taken: taken)
    }

    /// Takes the shared file before the callback returns, because the system deletes the
    /// file it lent as soon as it does. Moved rather than copied: the file is ours to take,
    /// and a move on the same disk is instant where copying a long video is not.
    /// Returns the staged file and the name the file was lent under.
    nonisolated private static func copy(_ provider: NSItemProvider, kind: Capture.Kind, into folder: URL) async -> (URL, String?)? {
        let type = type(for: kind)
        let fromFile: (URL, String?)? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "dat") : url.pathExtension
                let target = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
                do {
                    do {
                        try FileManager.default.moveItem(at: url, to: target)
                    } catch {
                        // Lent read-only or from another volume: fall back to a copy.
                        try FileManager.default.copyItem(at: url, to: target)
                    }
                    continuation.resume(returning: (target, url.lastPathComponent))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        if let fromFile { return fromFile }

        // Some apps (a screenshot's markup editor, for one) share an image as data only.
        guard kind == .photo else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return continuation.resume(returning: nil) }
                let ext = UIImage(data: data) != nil && data.starts(with: [0x89, 0x50]) ? "png" : "jpg"
                let target = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
                continuation.resume(returning: (try? data.write(to: target)) != nil ? (target, nil) : nil)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
            if let url { return url.absoluteString }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
        }
        return nil
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if model.preparing && model.hasMedia {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Sorting by day: \(model.preparedCount) of \(model.total)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(model.plan.days) { day in
                    DaySection(model: model, dayId: day.id, isOnly: model.plan.days.count == 1)
                }

                Section {
                    Button {
                        model.addDay()
                    } label: {
                        Label("Add a note for another day", systemImage: "plus")
                    }
                } footer: {
                    Text("Arranging an entry later works its notes in with everything else.")
                }

                if let problem = model.problem {
                    Section {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("DumpNotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { model.add() }
                        .disabled(!model.canAdd)
                }
            }
        }
    }
}

/// One day: its photos, a note about it, and where it goes.
private struct DaySection: View {
    @Bindable var model: ShareModel
    let dayId: UUID
    let isOnly: Bool
    @State private var moving: UUID?
    @State private var movingTo = Date()

    var body: some View {
        if let day = model.plan[dayId] {
            Section {
                if !day.fileIds.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 6) {
                            ForEach(day.fileIds, id: \.self) { fileId in
                                if let item = model.items[fileId] {
                                    // Tap for the menu: moving a misdated photo is common
                                    // enough that it shouldn't hide behind a long press.
                                    Menu {
                                        moveMenu(for: fileId, from: day)
                                        Button(role: .destructive) {
                                            model.remove(fileId)
                                        } label: {
                                            Label("Leave this one out", systemImage: "xmark")
                                        }
                                    } label: {
                                        ShareThumbnail(item: item)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 60)

                    if day.undated {
                        Text("These don\u{2019}t say when they were taken. Tap one to move it to its day, or pick a day below to move them all.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField(
                    isOnly && day.fileIds.isEmpty ? "What do you want to remember?" : "A note about this day",
                    text: Binding(
                        get: { model.plan[dayId]?.text ?? "" },
                        set: { model.plan[dayId]?.text = $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(2...10)

                DatePicker(
                    day.undated ? "Move all to" : "Day",
                    selection: Binding(
                        get: { day.day.representativeDate() },
                        set: { model.setDay($0, for: dayId) }
                    ),
                    in: ...Date(),
                    displayedComponents: .date
                )

                let existing = model.entries(on: day.day)
                if !day.undated && model.makesNewEntry(dayId) {
                    TextField("Title (optional)", text: Binding(
                        get: { model.plan[dayId]?.title ?? "" },
                        set: { model.plan[dayId]?.title = $0 }
                    ))
                    if day.title.isEmpty, let suggestion = model.suggestedTitle(for: dayId) {
                        Button {
                            model.plan[dayId]?.title = suggestion
                        } label: {
                            Label("Name it \u{201C}\(suggestion)\u{201D}", systemImage: "plus")
                        }
                        .font(.subheadline)
                    }
                }

                Picker("Entry", selection: Binding(
                    get: { day.entry.shown(among: existing) },
                    set: { model.plan[dayId]?.entry = $0 }
                )) {
                    Text("New entry").tag(CapturePlan.EntryChoice.new)
                    if !existing.isEmpty {
                        Section("Existing entries") {
                            ForEach(existing) { entry in
                                Text(entry.title).tag(CapturePlan.EntryChoice.existing(entry.id))
                            }
                        }
                    }
                }

                if !isOnly {
                    Button("Remove this day", role: .destructive) { model.removeDay(dayId) }
                        .font(.footnote)
                }
            } header: {
                Text(header(for: day))
            }
            .sheet(isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })) {
                NavigationStack {
                    DatePicker("Day", selection: $movingTo, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                        .navigationTitle("Move to")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { moving = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Move") {
                                    if let moving { model.move(moving, to: movingTo) }
                                    moving = nil
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    /// Every other day already here, then any day at all.
    @ViewBuilder
    private func moveMenu(for fileId: UUID, from day: CapturePlan.Day) -> some View {
        let others = model.plan.days.filter { !$0.undated && $0.id != day.id }
        if !others.isEmpty {
            Section("Move to") {
                ForEach(others) { other in
                    Button(other.day.representativeDate().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())) {
                        model.move(fileId, to: other.day.representativeDate())
                    }
                }
            }
        }
        Button {
            moving = fileId
        } label: {
            Label("Move to another day\u{2026}", systemImage: "calendar")
        }
    }

    private func header(for day: CapturePlan.Day) -> String {
        if day.undated {
            let count = day.fileIds.count
            return "No date found \u{00B7} \(count) \(count == 1 ? "item" : "items")"
        }
        let date = day.day.representativeDate().formatted(.dateTime.weekday(.wide).month(.wide).day())
        let count = day.fileIds.count
        return count == 0 ? date : "\(date) \u{00B7} \(count) \(count == 1 ? "item" : "items")"
    }
}

/// Drawn small from the staged file, so five hundred of them don't hold five hundred
/// full-size images in an extension's limited memory.
private struct ShareThumbnail: View {
    let item: ShareModel.Item
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
        .overlay(alignment: .bottomLeading) {
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .padding(4)
                    .shadow(radius: 2)
            }
        }
        .task(id: item.id) {
            let url = item.url
            let kind = item.kind
            image = await Task.detached { Self.thumbnail(url: url, kind: kind) }.value
        }
    }

    nonisolated private static func thumbnail(url: URL, kind: Capture.Kind) -> UIImage? {
        if kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 168, height: 168)
            return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init(cgImage:))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 168,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}
