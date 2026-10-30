import CodenamePromiseCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Your Mac: whether dumps from the Mac are in, coming, or stuck, and what's arrived lately.
///
/// Connecting is a one-time step. The phone can't go looking in iCloud Drive on its own;
/// picking the folder grants it access to that one folder, which it keeps until it's
/// disconnected.
///
/// The page says where things stand with a status card rather than paragraphs: up to date,
/// checking, some on the way down from iCloud, just added, or the folder can't be opened. It
/// checks when it appears and keeps checking while anything is on the way, so "on the way"
/// turns into "added" without anyone tapping.
struct MacInboxSection: View {
    @Environment(AppServices.self) private var services
    @State private var picking = false
    @State private var connectedName = CaptureInbox.macFolderName
    @State private var problem: String?
    @State private var status = Status.idle
    @State private var lastChecked: Date?
    @State private var arrivals: [InboxHistory.Arrival] = []
    @State private var confirmingDisconnect = false

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        /// What the last check brought in, as "2 photos and a note".
        case added(String)
        /// Dumps iCloud is still downloading.
        case onTheWay(Int)
        case unreachable
    }

    var body: some View {
        if connectedName != nil {
            connected
        } else {
            connect
        }
    }

    // MARK: - Not connected

    private var connect: some View {
        Section {
            Button {
                picking = true
            } label: {
                Label("Connect your Mac", systemImage: "laptopcomputer.and.arrow.down")
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Brand.failed)
            }
        } footer: {
            Text("Open DumpNotes Capture on your Mac once, then pick \u{201C}DumpNotes Inbox\u{201D} in iCloud Drive.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try CaptureInbox.connectMacFolder(url)
                connectedName = CaptureInbox.macFolderName
                problem = nil
                Task { await check() }
            } catch {
                problem = "Couldn\u{2019}t connect that folder. Try choosing it again."
            }
        }
    }

    // MARK: - Connected

    @ViewBuilder
    private var connected: some View {
        Section {
            StatusCard(status: status, lastChecked: lastChecked) {
                Task { await check() }
            }
        }
        .task {
            arrivals = CaptureInbox.history.arrivals(from: .mac)
            await check()
        }

        Section("Recently arrived") {
            if arrivals.isEmpty {
                Label("Nothing yet", systemImage: "tray")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(arrivals.prefix(30)) { arrival in
                    ArrivalRow(arrival: arrival)
                }
            }
        }

        // At the bottom, on its own and confirmed: it once sat right under "Check now",
        // close enough to tap by mistake.
        Section {
            LabeledContent {
                Text(connectedName ?? "").foregroundStyle(.secondary)
            } label: {
                Label("Folder", systemImage: "folder")
            }
            Button("Disconnect Mac", role: .destructive) {
                confirmingDisconnect = true
            }
            .confirmationDialog("Disconnect your Mac?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    CaptureInbox.disconnectMacFolder()
                    connectedName = nil
                    status = .idle
                }
            } message: {
                Text("Dumps from your Mac stop coming in. Nothing in your journal is removed.")
            }
        }
    }

    /// Files whatever is waiting and sets the status card. While anything is still coming
    /// down from iCloud it looks again every few seconds, for a couple of minutes.
    private func check() async {
        guard status != .checking else { return }
        var rounds = 0
        repeat {
            if rounds > 0 {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { return }
            } else {
                withAnimation { status = .checking }
            }
            guard let pass = await services.drainInbox() else {
                // Another pass was already running; it did the same work.
                lastChecked = Date()
                withAnimation {
                    arrivals = CaptureInbox.history.arrivals(from: .mac)
                    status = .upToDate
                }
                return
            }
            lastChecked = Date()
            withAnimation {
                arrivals = CaptureInbox.history.arrivals(from: .mac)
                status = Self.status(after: pass, previous: status)
            }
            rounds += 1
        } while status.isOnTheWay && rounds < 30
    }

    private static func status(after pass: CaptureInbox.Pass, previous: Status) -> Status {
        guard pass.reachedMac else { return .unreachable }
        let mac = pass.fromMac
        if pass.macWaiting > 0 { return .onTheWay(pass.macWaiting) }
        if !mac.isEmpty {
            return .added(CaptureInbox.list(photos: mac.photos, videos: mac.videos, recordings: mac.recordings, notes: mac.jots))
        }
        // Something added on an earlier round stays said until there's news.
        if case .added = previous { return previous }
        return .upToDate
    }
}

private extension MacInboxSection.Status {
    var isOnTheWay: Bool {
        if case .onTheWay = self { return true }
        return false
    }
}

// MARK: - Status card

/// Where things stand, at a glance: a coloured symbol, a few words, when it last looked,
/// and a button to look again.
private struct StatusCard: View {
    let status: MacInboxSection.Status
    let lastChecked: Date?
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                symbol
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Type.label(16))
                    .foregroundStyle(Brand.ink)
                    .contentTransition(.opacity)
                if let subtitle {
                    Text(subtitle)
                        .font(Type.caption(12.5))
                        .foregroundStyle(Brand.muted)
                }
            }
            Spacer(minLength: 8)
            if status == .checking {
                ProgressView()
            } else {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Check again")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var symbol: some View {
        switch status {
        case .onTheWay:
            Image(systemName: "icloud.and.arrow.down")
                .symbolEffect(.pulse, options: .repeating)
        case .idle, .checking:
            Image(systemName: "laptopcomputer")
        case .upToDate:
            Image(systemName: "checkmark")
        case .added:
            Image(systemName: "tray.and.arrow.down.fill")
        case .unreachable:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var tint: Color {
        switch status {
        case .idle, .checking: Brand.violet
        case .upToDate, .added: Brand.reached
        case .onTheWay: Color(uiColor: .systemBlue)
        case .unreachable: Brand.failed
        }
    }

    private var title: String {
        switch status {
        case .idle, .checking: "Checking your Mac\u{2026}"
        case .upToDate: "Up to date"
        case .added(let what): "Added \(what)"
        case .onTheWay(let count): count == 1 ? "1 on its way from iCloud" : "\(count) on their way from iCloud"
        case .unreachable: "Can\u{2019}t open the folder"
        }
    }

    private var subtitle: String? {
        switch status {
        case .onTheWay: return "Adding them as they land"
        case .unreachable: return "Disconnect below, then connect again"
        default:
            guard let lastChecked else { return nil }
            return "Checked \(lastChecked.formatted(.relative(presentation: .named)))"
        }
    }
}

// MARK: - Arrival row

/// One arrival: a thumbnail, the entry it went into, when, and what it brought as small
/// symbols with counts. Opens the entry.
private struct ArrivalRow: View {
    let arrival: InboxHistory.Arrival
    @Environment(AppServices.self) private var services

    var body: some View {
        if let summary, let files = services.files {
            NavigationLink {
                EntryScreen(id: arrival.entryId)
            } label: {
                HStack(spacing: 12) {
                    thumbnail(files)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.title).lineLimit(1)
                        HStack(spacing: 10) {
                            Text(when)
                            counts
                        }
                        .font(Type.caption(12))
                        .foregroundStyle(Brand.muted)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ files: MediaFileStore) -> some View {
        if let first = media.first {
            PhotoTile(thumb: DraftSummary.Thumb(id: first.id, relativePath: first.relativePath, isVideo: first.kind == .video),
                      fileStore: files, maxPixel: 132)
        } else {
            ZStack {
                Brand.panel
                Image(systemName: arrival.recordings > 0 ? "waveform" : "text.alignleft")
                    .foregroundStyle(Brand.muted)
            }
        }
    }

    private var counts: some View {
        let videos = media.filter { $0.kind == .video }.count
        let photos = media.count - videos
        return HStack(spacing: 8) {
            count(photos, "photo", "photos")
            count(videos, "video", "videos")
            count(arrival.recordings, "waveform", "recordings")
            count(arrival.notes, "text.alignleft", "notes")
        }
    }

    @ViewBuilder
    private func count(_ n: Int, _ symbol: String, _ noun: String) -> some View {
        if n > 0 {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text("\(n)").monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(n) \(noun)")
        }
    }

    /// The entry, or nothing when it has since been deleted.
    private var summary: DraftSummary? {
        guard let draft = try? services.store?.draft(id: arrival.entryId), !draft.isTrashed else { return nil }
        return DraftSummary(draft)
    }

    /// The photos and videos it brought that are still in the journal, in the order they came.
    private var media: [MediaItem] {
        let ids = arrival.mediaIds
        guard !ids.isEmpty else { return [] }
        let items = (try? services.store?.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        return items.sorted { (ids.firstIndex(of: $0.id) ?? 0) < (ids.firstIndex(of: $1.id) ?? 0) }
    }

    private var when: String {
        let date = arrival.date
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "Just now" }
        if age < 60 * 60 * 12 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
