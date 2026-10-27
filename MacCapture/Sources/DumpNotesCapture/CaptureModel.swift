import AppKit
import CodenamePromiseCore
import Foundation
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// What's in the panel, arranged by day, and writing it out.
///
/// Every photo or video sorts itself into the day it was taken as it's added, and each day has
/// its own note and its own entry. A note can be written for any day, with or without photos.
@MainActor
@Observable
final class CaptureModel {
    struct Item: Identifiable, Equatable {
        /// Also the attachment's id in the journal.
        let id: UUID
        let url: URL
        let kind: Capture.Kind
        /// True for files this app made (a pasted screenshot, a drag out of Photos), which are
        /// moved rather than copied and so don't leave a second copy behind.
        let owned: Bool
        var thumbnail: NSImage?
    }

    var plan = CapturePlan()
    private(set) var items: [UUID: Item] = [:]
    /// Files whose date is still being read, so the button waits for them.
    private(set) var reading = 0

    private(set) var saving = false
    private(set) var problem: String?
    private(set) var justAdded: String?
    private(set) var waiting = 0
    private(set) var index: EntryIndex?

    /// Asks one day's note field to take focus.
    private(set) var focusDay: UUID?
    private(set) var focusRequest = 0

    var onFinished: () -> Void = {}

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/DumpNotes Inbox`, which the Files app
    /// and Finder both show as "DumpNotes Inbox" at the top of iCloud Drive.
    ///
    /// `DumpNotesInboxPath` in this app's defaults overrides it, for testing against a
    /// simulator without going through iCloud.
    let inbox: URL = {
        if let path = UserDefaults.standard.string(forKey: "DumpNotesInboxPath") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/DumpNotes Inbox", isDirectory: true)
    }()

    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("DumpNotesCapture", isDirectory: true)

    func prepareInbox() {
        let iCloudDrive = inbox.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: iCloudDrive.path) else {
            problem = "iCloud Drive isn\u{2019}t turned on for this Mac, so your iPhone won\u{2019}t see these. Turn it on in System Settings, Apple Account, iCloud."
            return
        }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func refresh() {
        index = EntryIndex.read(from: inbox.appendingPathComponent(EntryIndex.fileName))
        let scan = InboxScanner().scan(inbox)
        waiting = scan.ready.count + scan.arriving.count
    }

    func requestFocus(_ day: UUID? = nil) {
        focusDay = day ?? plan.days.first?.id
        focusRequest += 1
    }

    // MARK: - Days

    func entries(on day: CalendarDay) -> [EntryIndex.Entry] {
        index?.entries(on: day) ?? []
    }

    func setDay(_ date: Date, for id: UUID) {
        guard var day = plan[id] else { return }
        day.day = CalendarDay(date: date)
        // An entry picked on the old day doesn't belong to the new one.
        if case .existing = day.entry { day.entry = .latest }
        plan[id] = day
    }

    func addDay() {
        // The day before the earliest one here: filling in a gap is the usual reason.
        let earliest = plan.days.map(\.day).min() ?? .today()
        let id = plan.addDay(CalendarDay(date: earliest.representativeDate().addingTimeInterval(-86_400)))
        requestFocus(id)
    }

    func removeDay(_ id: UUID) {
        for fileId in plan[id]?.fileIds ?? [] { discard(fileId) }
        plan.removeDay(id)
    }

    var canAdd: Bool { !saving && reading == 0 && !plan.isEmpty }

    // MARK: - Adding things

    func add(urls: [URL]) {
        for url in urls {
            guard let kind = Capture.Kind.infer(fromExtension: url.pathExtension)
                    ?? Self.kindFromType(url) else {
                problem = "\(url.lastPathComponent) isn\u{2019}t a photo, video, recording or text file."
                continue
            }
            guard !items.values.contains(where: { $0.url == url }) else { continue }
            if kind == .text, let contents = try? String(contentsOf: url, encoding: .utf8) {
                // Text reads better as a note than as an attachment nobody opens.
                appendNote(contents)
                continue
            }
            add(Item(id: UUID(), url: url, kind: kind, owned: false))
        }
    }

    private func appendNote(_ text: String) {
        guard let first = plan.days.first else { return }
        let current = plan[first.id]?.text ?? ""
        plan[first.id]?.text = current.isEmpty ? text : current + "\n\n" + text
    }

    /// Reads the file's own date, then files it under that day.
    private func add(_ item: Item) {
        items[item.id] = item
        reading += 1
        loadThumbnail(for: item)
        Task {
            let taken = await Self.takenOn(item)
            plan.place(item.id, on: taken ?? .today())
            reading -= 1
        }
    }

    /// A drop. Finder hands over file URLs; Photos hands over the image or movie itself,
    /// as a file that only exists until the callback returns, so it is copied out first.
    func add(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.add(urls: [url]) }
                }
                continue
            }
            let type: UTType? = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? .movie
                : provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? .image : nil
            guard let type else { continue }
            let kind: Capture.Kind = type == .movie ? .video : .photo
            let scratch = self.scratch
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    Task { @MainActor in self.problem = "Couldn\u{2019}t read one of those. Try dragging it to the desktop first." }
                    return
                }
                let target = scratch.appendingPathComponent("\(UUID().uuidString.prefix(8)) \(url.lastPathComponent)")
                guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
                Task { @MainActor in self.add(Item(id: UUID(), url: target, kind: kind, owned: true)) }
            }
        }
    }

    /// ⌘V. Returns false when there's nothing but text on the pasteboard, so the note field
    /// handles it as normal.
    func paste() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls: urls)
            return true
        }
        // A screenshot taken with ⌃⇧⌘4 lands on the pasteboard as image data, not a file.
        if board.string(forType: .string) == nil,
           let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let url = scratch.appendingPathComponent("Pasted \(UUID().uuidString.prefix(8)).png")
            do {
                try png.write(to: url)
                add(Item(id: UUID(), url: url, kind: .photo, owned: true, thumbnail: image))
            } catch {
                problem = "Couldn\u{2019}t paste that image."
            }
            return true
        }
        return false
    }

    func remove(_ fileId: UUID) {
        discard(fileId)
        plan.remove(file: fileId)
    }

    private func discard(_ fileId: UUID) {
        if let item = items.removeValue(forKey: fileId), item.owned {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .audio, .plainText]
        panel.message = "Choose photos, videos, recordings or text to add"
        panel.prompt = "Add"
        panel.level = .floating
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    // MARK: - Previewing

    /// Every attached file, in the order shown, for Quick Look to page through.
    var previewItems: [Item] {
        plan.days.flatMap { $0.fileIds.compactMap { items[$0] } }
    }
    private(set) var previewIndex = 0
    var onPreview: () -> Void = {}

    func preview(_ fileId: UUID) {
        previewIndex = previewItems.firstIndex { $0.id == fileId } ?? 0
        onPreview()
    }

    // MARK: - Saving

    func dump() {
        guard canAdd else { return }
        saving = true
        problem = nil

        let plan = self.plan
        let sources = plan.days.flatMap(\.fileIds).compactMap { id in
            items[id].map { CaptureWriter.Source(url: $0.url, kind: $0.kind, move: $0.owned, id: id) }
        }
        let writer = CaptureWriter(inbox: inbox)
        let summary = Self.summary(plan: plan, items: Array(items.values))

        // Off the main thread: copying a few large videos takes a moment.
        Task.detached {
            do {
                try writer.write(plan: plan, sources: sources, source: "mac")
                await self.finished(summary)
            } catch {
                await self.failed()
            }
        }
    }

    private func finished(_ summary: String) {
        saving = false
        plan = CapturePlan()
        items = [:]
        justAdded = summary
        refresh()
        // Long enough to read, short enough not to be in the way.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            onFinished()
            try? await Task.sleep(for: .seconds(2))
            justAdded = nil
        }
    }

    private func failed() {
        saving = false
        problem = "Couldn\u{2019}t save that. Everything is still here, so you can try again."
    }

    // MARK: - Helpers

    /// The day a file was taken: from its own metadata, else (for a file from Finder) the day
    /// the file was made, which for a screenshot is the day it was taken.
    private static func takenOn(_ item: Item) async -> CalendarDay? {
        var date: Date?
        switch item.kind {
        case .photo: date = CaptureDateReader.captureDate(ofImageAt: item.url)
        case .video: date = await CaptureDateReader.captureDate(ofVideoAt: item.url)
        case .audio, .text: date = nil
        }
        if date == nil, !item.owned {
            date = (try? item.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        }
        return date.map { CalendarDay(date: $0) }
    }

    private static func kindFromType(_ url: URL) -> Capture.Kind? {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .photo }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .plainText) { return .text }
        return nil
    }

    private func loadThumbnail(for item: Item) {
        guard item.thumbnail == nil else { return }
        let url = item.url
        let id = item.id
        Task {
            let image = await Thumbnails.make(for: url)
            items[id]?.thumbnail = image
        }
    }

    private static func summary(plan: CapturePlan, items: [Item]) -> String {
        let photos = items.filter { $0.kind == .photo }.count
        let videos = items.filter { $0.kind == .video }.count
        let other = items.count - photos - videos
        let notes = plan.days.filter(\.hasNote).count
        var parts: [String] = []
        if notes > 0 { parts.append(notes == 1 ? "1 note" : "\(notes) notes") }
        if photos > 0 { parts.append(photos == 1 ? "1 photo" : "\(photos) photos") }
        if videos > 0 { parts.append(videos == 1 ? "1 video" : "\(videos) videos") }
        if other > 0 { parts.append(other == 1 ? "1 file" : "\(other) files") }
        return "Added " + parts.joined(separator: ", ")
    }
}

enum Thumbnails {
    static func make(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 120, height: 120), scale: 2, representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
