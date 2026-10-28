import AVFoundation
import CodenamePromiseCore
import ImageIO
import Observation
import Photos
import UniformTypeIdentifiers

/// Fills the journal in from the Photos library: every photo and video, filed under the day
/// it was taken, in that day's entry or a new one.
///
/// For bringing a whole camera roll in once the written journal is all here. Phone-friendly
/// copies, the same as the rest of the migration: photos at 2048 pixels on the long side
/// with their metadata (date, place, camera) kept, videos at 1080p. DumpNotes keeps its own
/// copy of everything, so nothing in the journal depends on the library staying as it is.
///
/// Safe to run again whenever: each copy's id comes from the library item, so a second run
/// adds only what's new. A photo that's the same picture as one the day's entry already has
/// (one that came in through an earlier import, say) is left out. Lives as long as the app,
/// keeps going in the background with a Live Activity, and picks up again after a restart.
@MainActor
@Observable
final class PhotoBackfillCoordinator {
    struct Summary: Equatable {
        var photos = 0
        var videos = 0
        var days = 0
        var daysWithEntries = 0
        var alreadyIn = 0
        /// Similar shots left out on an earlier fill.
        var leftOut = 0
        var similarGroups = 0
        var similarPhotos = 0
    }

    /// Photos taken seconds apart that look alike: the twenty frames of one view, taken to
    /// get one good one. Shown for review before anything is copied; only the ones kept
    /// come in.
    struct SimilarGroup: Identifiable, Equatable {
        var id: String { assets[0].id }
        let day: CalendarDay
        let assets: [PhotoBackfill.Asset]
        /// Library ids to bring in. Starts as the favourite(s), or the first frame.
        var keep: Set<String>
    }

    struct Outcome: Equatable {
        var added = 0
        var duplicates = 0
        var newEntries = 0
        var unreadable = 0
    }

    enum Phase: Equatable {
        case idle
        case noAccess
        case scanning
        case ready(Summary)
        case working(done: Int, total: Int, day: CalendarDay)
        case done(Outcome)
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// What the scan is doing, for the line under its spinner.
    private(set) var scanNote = ""
    private(set) var groups: [SimilarGroup] = []
    private var plan: [PhotoBackfill.Day] = []

    private let store: DraftStore
    private let fileStore: MediaFileStore

    /// Set while a fill is running, so one cut off by the app closing carries on next launch.
    private static let inProgressKey = "photoBackfill.inProgress"
    /// Library ids left out of a run of similar shots, so a later fill doesn't offer them again.
    private static let leftOutKey = "photoBackfill.leftOut"

    private var leftOut: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.leftOutKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.leftOutKey) }
    }

    init(store: DraftStore, fileStore: MediaFileStore) {
        self.store = store
        self.fileStore = fileStore
        if UserDefaults.standard.bool(forKey: Self.inProgressKey) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await self.scan()
                if case .ready = self.phase { self.start() }
            }
        }
    }

    var isWorking: Bool {
        switch phase {
        case .scanning, .working: true
        default: false
        }
    }

    // MARK: - Looking

    /// Reads the library and works out what's new, without copying anything.
    func scan() async {
        guard !isWorking else { return }
        guard await PhotoDateFinder.requestAccess() else {
            phase = .noAccess
            return
        }
        phase = .scanning
        scanNote = "Looking through your library"
        let assets = await Task.detached(priority: .userInitiated) { Self.libraryAssets() }.value
        let alreadyIn = (try? store.allMediaIds()) ?? []
        let skipped = leftOut
        plan = PhotoBackfill.plan(assets, alreadyIn: alreadyIn, leftOut: skipped)
        scanNote = "Checking for runs of similar shots"
        groups = await Self.similarGroups(in: plan)

        var summary = Summary()
        let entryDays = Set(((try? store.allDrafts()) ?? []).map(\.entryDateKey))
        for day in plan {
            summary.days += 1
            if entryDays.contains(day.day.rawValue) { summary.daysWithEntries += 1 }
            for asset in day.assets {
                if asset.isVideo { summary.videos += 1 } else { summary.photos += 1 }
            }
        }
        summary.leftOut = assets.filter { skipped.contains($0.id) }.count
        summary.alreadyIn = assets.count - plan.reduce(0) { $0 + $1.assets.count } - summary.leftOut
        summary.similarGroups = groups.count
        summary.similarPhotos = groups.reduce(0) { $0 + $1.assets.count }
        phase = .ready(summary)
    }

    /// Every photo and video in the library, hidden ones left out.
    nonisolated private static func libraryAssets() -> [PhotoBackfill.Asset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PhotoBackfill.Asset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate ?? asset.modificationDate else { return }
            assets.append(PhotoBackfill.Asset(id: asset.localIdentifier, date: date, isVideo: asset.mediaType == .video))
        }
        return assets
    }

    // MARK: - Filling in

    func start() {
        guard case .ready = phase, !plan.isEmpty else { return }
        // The frames of each similar run that weren't kept stay out, now and next time.
        let dropped = Set(groups.flatMap { group in group.assets.map(\.id).filter { !group.keep.contains($0) } })
        leftOut = leftOut.union(dropped)
        let plan = self.plan.compactMap { day -> PhotoBackfill.Day? in
            var day = day
            day.assets.removeAll { dropped.contains($0.id) }
            return day.assets.isEmpty ? nil : day
        }
        guard !plan.isEmpty else {
            phase = .done(Outcome())
            return
        }
        Task { await run(plan) }
    }

    func reset() {
        if !isWorking { phase = .idle }
    }

    private func run(_ plan: [PhotoBackfill.Day]) async {
        UserDefaults.standard.set(true, forKey: Self.inProgressKey)
        let total = plan.reduce(0) { $0 + $1.assets.count }
        let titles: [String] = ((try? store.allDrafts()) ?? []).compactMap(\.content.title)
        let prefix = TitleSuggestion.prefix(from: titles)
        var outcome = Outcome()
        phase = .working(done: 0, total: total, day: plan[0].day)

        await BackgroundWork.run(title: "Filling in from Photos") { report in
            var done = 0
            for day in plan {
                await self.fill(day, prefix: prefix, done: &done, total: total, outcome: &outcome, report: report)
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
        self.plan = []
        phase = .done(outcome)
        // Thumbnails for everything that just arrived, made in the background.
        ThumbnailWarmer.warm(container: store.context.container, files: fileStore)
    }

    /// One day: copies its items and files them into the day's entry, starting one if need be.
    private func fill(
        _ day: PhotoBackfill.Day,
        prefix: String,
        done: inout Int,
        total: Int,
        outcome: inout Outcome,
        report: BackgroundWork.Report
    ) async {
        phase = .working(done: done, total: total, day: day.day)
        let existing: [EntryDraft] = (try? store.drafts(on: day.day)) ?? []
        // What the day already has, so the same photo or video isn't added twice.
        let media: [MediaItem] = existing.flatMap(\.orderedMedia)
        let photoPaths: [URL] = media.filter { $0.kind == .photo }.map { fileStore.url(for: $0.relativePath) }
        let videoPaths: [URL] = media.filter { $0.kind == .video }.map { fileStore.url(for: $0.relativePath) }
        let known: Known = await Self.known(photos: photoPaths, videos: videoPaths)

        var entry: EntryDraft? = existing.max { $0.updatedAt < $1.updatedAt }
        let prepared: [(PhotoBackfill.Asset, Prepared)] = await Self.prepare(day.assets, into: fileStore, alongside: known)
        for (asset, file) in prepared {
            done += 1
            report(done, total, "\(done) of \(total)")
            guard case .ready(let adopted) = file else {
                if case .duplicate = file { outcome.duplicates += 1 } else { outcome.unreadable += 1 }
                continue
            }
            do {
                let target: EntryDraft
                if let entry {
                    target = entry
                } else {
                    // A day with photos and no entry gets one, named the way the rest of
                    // the journal is.
                    target = try store.createDraft(entryDate: day.day)
                    try store.updateTitle(TitleSuggestion.title(prefix: prefix, day: day.day), for: target)
                    entry = target
                    outcome.newEntries += 1
                }
                try store.record(adopted, kind: asset.isVideo ? .video : .photo, to: target, saving: false)
                outcome.added += 1
            } catch {
                fileStore.delete(relativePaths: [adopted.relativePath])
                outcome.unreadable += 1
            }
        }
        // Saved a day at a time, so an interruption costs at most the day in hand, and the
        // next run adds it then.
        try? store.flush()
    }

    // MARK: - Similar shots

    func setKeep(_ assetId: String, _ keep: Bool, in groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        if keep { groups[index].keep.insert(assetId) } else { groups[index].keep.remove(assetId) }
    }

    func keepAll(in groupId: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[index].keep = Set(groups[index].assets.map(\.id))
    }

    /// Finds the runs of similar shots among what's about to come in: photos seconds apart
    /// (`PhotoBackfill.runs`), split wherever one frame stops looking like the one before.
    nonisolated private static func similarGroups(in plan: [PhotoBackfill.Day]) async -> [SimilarGroup] {
        await Task.detached(priority: .userInitiated) {
            var groups: [SimilarGroup] = []
            for day in plan {
                for run in PhotoBackfill.runs(day.assets) {
                    groups += clusters(of: run, on: day.day)
                }
            }
            return groups
        }.value
    }

    nonisolated private static func clusters(of run: [PhotoBackfill.Asset], on day: CalendarDay) -> [SimilarGroup] {
        let items = PHAsset.fetchAssets(withLocalIdentifiers: run.map(\.id), options: nil)
        var byId: [String: PHAsset] = [:]
        items.enumerateObjects { asset, _, _ in byId[asset.localIdentifier] = asset }
        let prints: [PhotoDateFinder.Fingerprint?] = run.map { byId[$0.id].flatMap(thumbnailFingerprint(of:)) }

        var groups: [SimilarGroup] = []
        var cluster: [Int] = [0]
        func close() {
            guard cluster.count > 1 else { return }
            let members = cluster.map { run[$0] }
            let favourites = Set(members.filter { byId[$0.id]?.isFavorite == true }.map(\.id))
            groups.append(SimilarGroup(day: day, assets: members, keep: favourites.isEmpty ? [members[0].id] : favourites))
        }
        for index in 1..<run.count {
            var alike = false
            if let a = prints[index - 1], let b = prints[index] { alike = a.distance(to: b) < 22 }
            if alike { cluster.append(index) } else { close(); cluster = [index] }
        }
        close()
        return groups
    }

    /// A fingerprint from the library's own small thumbnail, which is on the phone even when
    /// the original is only in iCloud, so checking thousands of photos stays quick.
    nonisolated static func thumbnailFingerprint(of asset: PHAsset) -> PhotoDateFinder.Fingerprint? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        // High quality at this size is still the small thumbnail kept on the phone; the fast
        // format can come back empty, which would read as "not alike" and miss the run.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        var image: CGImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 64, height: 64),
                                              contentMode: .aspectFill, options: options) { result, _ in
            image = result?.cgImage
        }
        return image.flatMap { PhotoDateFinder.Fingerprint(image: $0) }
    }

    // MARK: - Copies

    private enum Prepared: Sendable {
        case ready(AdoptedFile)
        case duplicate
        case unreadable
    }

    /// Phone-friendly copies of a day's items, four at a time, adopted into the store and in
    /// the order taken. Off the main actor: this is the slow part (iCloud downloads, video
    /// encoding).
    nonisolated private static func prepare(
        _ assets: [PhotoBackfill.Asset],
        into fileStore: MediaFileStore,
        alongside known: Known
    ) async -> [(PhotoBackfill.Asset, Prepared)] {
        await withTaskGroup(of: (Int, Prepared).self) { group -> [(PhotoBackfill.Asset, Prepared)] in
            var results = [Prepared](repeating: .unreadable, count: assets.count)
            var next = 0
            func start() {
                guard next < assets.count else { return }
                let index = next
                next += 1
                let asset = assets[index]
                group.addTask { (index, await copy(asset, into: fileStore, alongside: known)) }
            }
            for _ in 0..<4 { start() }
            while let (index, prepared) = await group.next() {
                results[index] = prepared
                start()
            }
            return Array(zip(assets, results))
        }
    }

    nonisolated private static func copy(
        _ asset: PhotoBackfill.Asset,
        into fileStore: MediaFileStore,
        alongside known: Known
    ) async -> Prepared {
        guard let item = PHAsset.fetchAssets(withLocalIdentifiers: [asset.id], options: nil).firstObject else {
            return .unreadable
        }
        // Checked from the library's small thumbnail first, before anything is downloaded
        // from iCloud or encoded: a duplicate costs a glance, not a copy.
        if known.has(item, isVideo: asset.isVideo) { return .duplicate }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-\(UUID().uuidString).\(asset.isVideo ? "mov" : "jpg")")
        defer { try? FileManager.default.removeItem(at: temporary) }

        if asset.isVideo {
            guard await exportVideo(item, to: temporary) else { return .unreadable }
        } else {
            guard let data = photoData(item), writeJPEG(from: data, to: temporary) else { return .unreadable }
            if let print = fingerprint(of: temporary), known.photos.contains(where: { $0.distance(to: print) < 10 }) {
                return .duplicate
            }
        }
        guard let adopted = try? fileStore.adopt(fileAt: temporary, id: PhotoBackfill.mediaId(forAsset: asset.id)) else {
            return .unreadable
        }
        return .ready(adopted)
    }

    /// What a day's entries already hold, to recognise the same photo or video coming in
    /// again (from an earlier import of the same day, say).
    struct Known: Sendable {
        var photos: [PhotoDateFinder.Fingerprint] = []
        /// A video's length and its opening frame. Length alone matches too easily; the frame
        /// alone misses a video that opens on black.
        var videos: [(seconds: Double, frame: PhotoDateFinder.Fingerprint?)] = []

        func has(_ asset: PHAsset, isVideo: Bool) -> Bool {
            if isVideo {
                let sameLength = videos.filter { abs($0.seconds - asset.duration) < 0.35 }
                guard !sameLength.isEmpty else { return false }
                let frame = PhotoBackfillCoordinator.thumbnailFingerprint(of: asset)
                return sameLength.contains { existing in
                    guard let a = existing.frame, let b = frame else {
                        // No frame to compare: only an exact match on length counts.
                        return abs(existing.seconds - asset.duration) < 0.05
                    }
                    return a.distance(to: b) < 25
                }
            }
            guard !photos.isEmpty, let print = PhotoBackfillCoordinator.thumbnailFingerprint(of: asset) else { return false }
            return photos.contains { $0.distance(to: print) < 12 }
        }
    }

    nonisolated private static func known(photos: [URL], videos: [URL]) async -> Known {
        var known = Known()
        known.photos = await Task.detached { photos.compactMap(fingerprint(of:)) }.value
        for url in videos {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.isNumeric else { continue }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 128, height: 128)
            let frame = (try? await generator.image(at: .zero).image).flatMap { PhotoDateFinder.Fingerprint(image: $0) }
            known.videos.append((duration.seconds, frame))
        }
        return known
    }

    /// The photo as Photos shows it (edits included), downloading from iCloud if need be.
    nonisolated private static func photoData(_ asset: PHAsset) -> Data? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        var result: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            result = data
        }
        return result
    }

    /// At most 2048 pixels on the long side, as JPEG, with the original's metadata carried
    /// over (when and where it was taken, the camera, its orientation).
    nonisolated private static func writeJPEG(from data: Data, to url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationImageMaxPixelSize: 2048,
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The export session, carried across the hop from Photos' callback. Used by one task
    /// at a time, start to finish.
    private struct ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession?
    }

    /// 1080p HEVC, downloading from iCloud if need be.
    ///
    /// Two plain steps rather than one nested callback: the nested version (a session from
    /// Photos' callback, exported inside it) sent the Swift compiler into a loop it never
    /// came out of, which hung every build.
    nonisolated private static func exportVideo(_ asset: PHAsset, to url: URL) async -> Bool {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        let box: ExportBox = await withCheckedContinuation { (continuation: CheckedContinuation<ExportBox, Never>) in
            PHImageManager.default().requestExportSession(
                forVideo: asset, options: options, exportPreset: AVAssetExportPresetHEVC1920x1080
            ) { session, _ in
                continuation.resume(returning: ExportBox(session: session))
            }
        }
        guard let session = box.session else { return false }
        session.outputURL = url
        session.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        return session.status == .completed
    }

    nonisolated private static func fingerprint(of url: URL) -> PhotoDateFinder.Fingerprint? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return PhotoDateFinder.Fingerprint(source: source)
    }
}
