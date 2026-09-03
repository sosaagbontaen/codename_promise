import CodenamePromiseCore
import SwiftUI

/// Bringing a journal back in from a folder this app once wrote.
///
/// The export was a one-way door: markdown you can read is not a journal you can restore, and
/// a backup you cannot re-open is a keepsake. This is the way back, and it is also how you
/// move between phones without relying on Apple's backup.
///
/// **It takes a folder, not the zip.** The export hands you a `.zip` because that is what you
/// can send somewhere; iOS has no public API for reading one back, and rather than take a
/// dependency for it, this asks for the uncompressed folder. Files does that with one tap,
/// and the copy says so instead of leaving somebody to discover it.
struct ImportView: View {
    let store: DraftStore
    let fileStore: MediaFileStore

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .idle
    @State private var picking = false

    enum Phase: Equatable {
        case idle
        case working
        case done(DraftStore.ImportReport)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch phase {
                    case .idle:
                        Button {
                            picking = true
                        } label: {
                            Label("Choose a journal folder", systemImage: "folder.badge.plus")
                        }

                    case .working:
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading it in\u{2026}")
                        }

                    case .done(let report):
                        Label(headline(report), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.reached)
                        reportRows(report)

                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.failed)
                    }
                } footer: {
                    Text("Pick the folder an export produced. If you have the zip, uncompress it in Files first, then choose the folder inside.\n\nNothing already on this phone is changed or removed. An entry that is already here is left alone, so importing the same folder twice is safe.")
                }
            }
            .navigationTitle("Import a journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(phase == .idle ? "Cancel" : "Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $picking,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { run(url) }
                case .failure(let error):
                    // Cancelling is a `.failure` on some paths and is not an error.
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func headline(_ report: DraftStore.ImportReport) -> String {
        if report.added == 0 && report.alreadyPresent > 0 {
            return "Everything in that folder was already here"
        }
        let noun = report.added == 1 ? "entry" : "entries"
        return "Brought in \(report.added) \(noun)"
    }

    @ViewBuilder
    private func reportRows(_ report: DraftStore.ImportReport) -> some View {
        if report.alreadyPresent > 0 {
            row("Already on this phone", "\(report.alreadyPresent)", Brand.muted)
        }
        if report.attachments > 0 {
            row("Photos and recordings", "\(report.attachments)", Brand.muted)
        }
        // Said plainly rather than buried. An import that quietly dropped things would be
        // worse than one that failed, because you would not know to go looking.
        if !report.missingAttachments.isEmpty {
            row(
                "Attachments not in the folder",
                "\(report.missingAttachments.count)",
                Brand.waiting
            )
            Text("Those entries came in with their words. Only the files were missing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !report.unreadable.isEmpty {
            row("Files that could not be read", "\(report.unreadable.count)", Brand.waiting)
        }
    }

    private func row(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(tint).monospacedDigit()
        }
        .font(.subheadline)
    }

    private func run(_ folder: URL) {
        phase = .working
        // A folder from the document picker lives outside the sandbox and has to be opened
        // explicitly, and closed even when the read throws.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        do {
            let report = try store.importJournal(from: folder, fileStore: fileStore)
            Haptics.picked()
            phase = .done(report)
        } catch {
            Haptics.failed()
            phase = .failed(error.localizedDescription)
        }
    }
}
