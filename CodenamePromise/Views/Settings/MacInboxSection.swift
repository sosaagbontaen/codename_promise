import CodenamePromiseCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Connects the phone to the folder the Mac capture panel writes to, and shows what's come
/// in from it.
///
/// Connecting is a one-time step. The phone can't go looking in iCloud Drive on its own;
/// picking the folder here grants it access to that one folder, which it keeps until it's
/// disconnected.
///
/// The phone files whatever is in the folder each time DumpNotes opens, and the folder is
/// emptied as it goes, so by the time anyone taps "Check now" there is usually nothing left
/// to find. That's why this lists what arrived, rather than only what's waiting.
struct MacInboxSection: View {
    @Environment(AppServices.self) private var services
    @State private var picking = false
    @State private var connectedName = CaptureInbox.macFolderName
    @State private var problem: String?
    @State private var checking = false
    /// What the last "Check now" found, said in a line under the button.
    @State private var checkResult: String?
    @State private var arrivals: [InboxHistory.Arrival] = []
    @State private var confirmingDisconnect = false

    var body: some View {
        Section {
            if let connectedName {
                LabeledContent {
                    Text(connectedName).foregroundStyle(.secondary)
                } label: {
                    Label("Mac inbox", systemImage: "laptopcomputer.and.arrow.down")
                }
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Check now")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(checking)
                if let checkResult {
                    Text(checkResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    picking = true
                } label: {
                    Label("Connect your Mac", systemImage: "laptopcomputer.and.arrow.down")
                }
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Brand.failed)
            }
        } footer: {
            Text(connectedName == nil
                 ? "Open DumpNotes Capture on your Mac once, then choose its \u{201C}DumpNotes Inbox\u{201D} folder in iCloud Drive."
                 : "Anything you dump on your Mac is added to your journal each time you open DumpNotes, so it\u{2019}s usually in before you check.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    try CaptureInbox.connectMacFolder(url)
                    connectedName = CaptureInbox.macFolderName
                    problem = nil
                    Task { await check() }
                } catch {
                    problem = "Couldn\u{2019}t connect that folder. Try choosing it again."
                }
            case .failure:
                break
            }
        }
        .onAppear { arrivals = CaptureInbox.history.arrivals(from: .mac) }

        if connectedName != nil {
            Section {
                if arrivals.isEmpty {
                    Text("Nothing yet. Dumps from your Mac will be listed here once they\u{2019}re in your journal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(arrivals.prefix(30)) { arrival in
                        ArrivalRow(arrival: arrival)
                    }
                }
            } header: {
                Text("Recently from your Mac")
            }

            // At the bottom, on its own and confirmed: it sat right under "Check now",
            // close enough to tap by mistake.
            Section {
                Button("Disconnect Mac", role: .destructive) {
                    confirmingDisconnect = true
                }
                .confirmationDialog("Disconnect your Mac?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        CaptureInbox.disconnectMacFolder()
                        connectedName = nil
                        checkResult = nil
                    }
                } message: {
                    Text("Dumps from your Mac will stop coming in until you connect it again. Nothing already in your journal is removed.")
                }
            }
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        guard let pass = await services.drainInbox() else {
            // Another pass was already running; it'll have done the same work.
            arrivals = CaptureInbox.history.arrivals(from: .mac)
            return
        }
        arrivals = CaptureInbox.history.arrivals(from: .mac)
        let mac = pass.fromMac
        var lines: [String] = []
        if !pass.reachedMac {
            lines.append("Couldn\u{2019}t open the Mac inbox folder. Try disconnecting and connecting it again.")
        } else if mac.isEmpty {
            lines.append("Nothing new waiting.")
        } else {
            lines.append("Brought in \(CaptureInbox.list(photos: mac.photos, videos: mac.videos, recordings: mac.recordings, notes: mac.jots)).")
        }
        if pass.macWaiting > 0 {
            lines.append("\(pass.macWaiting) still coming down from iCloud. They\u{2019}ll be added once they arrive.")
        }
        if pass.macFailed > 0 {
            lines.append("\(pass.macFailed) couldn\u{2019}t be read yet and will be tried again.")
        }
        checkResult = lines.joined(separator: " ")
    }
}

/// One arrival: which entry it went into, when, and what it brought. Opens the entry.
private struct ArrivalRow: View {
    let arrival: InboxHistory.Arrival
    @Environment(AppServices.self) private var services

    var body: some View {
        if let title {
            NavigationLink {
                EntryScreen(id: arrival.entryId)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text("\(when) \u{00B7} \(contents)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The entry's title, or nothing when it has since been deleted.
    private var title: String? {
        guard let draft = try? services.store?.draft(id: arrival.entryId), !draft.isTrashed else { return nil }
        // Titled the way the journal titles it, so it's recognisably the same entry.
        return DraftSummary(draft).title
    }

    /// What it brought, telling photos from videos where they're still in the journal.
    private var contents: String {
        let ids = arrival.mediaIds
        let items = (try? services.store?.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let videos = items.filter { $0.kind == .video }.count
        let photos = items.count - videos
        return CaptureInbox.list(photos: photos, videos: videos, media: arrival.media - items.count,
                                 recordings: arrival.recordings, notes: arrival.notes)
    }

    private var when: String {
        let date = arrival.date
        if Calendar.current.isDateInToday(date) { return "Today, \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
