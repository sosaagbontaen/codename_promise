import SwiftUI
import UniformTypeIdentifiers

/// Connects the phone to the folder the Mac capture panel writes to.
///
/// A one-time step. The phone can't go looking in iCloud Drive on its own; picking the folder
/// here grants it access to that one folder, which it keeps until it's disconnected.
struct MacInboxSection: View {
    @Environment(AppServices.self) private var services
    @State private var picking = false
    @State private var connectedName = CaptureInbox.macFolderName
    @State private var problem: String?

    var body: some View {
        Section {
            if let connectedName {
                LabeledContent {
                    Text(connectedName).foregroundStyle(.secondary)
                } label: {
                    Label("Mac inbox", systemImage: "laptopcomputer.and.arrow.down")
                }
                Button("Check now") {
                    Task { await services.drainInbox() }
                }
                Button("Disconnect", role: .destructive) {
                    CaptureInbox.disconnectMacFolder()
                    self.connectedName = nil
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
                 : "Anything you dump on your Mac shows up here the next time you open DumpNotes.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    try CaptureInbox.connectMacFolder(url)
                    connectedName = CaptureInbox.macFolderName
                    problem = nil
                    Task { await services.drainInbox() }
                } catch {
                    problem = "Couldn\u{2019}t connect that folder. Try choosing it again."
                }
            case .failure:
                break
            }
        }
    }
}
