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
///
/// The import itself belongs to `JournalImportCoordinator`, so closing this screen or leaving
/// the app doesn't stop it.
struct ImportView: View {
    let importer: JournalImportCoordinator

    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var picking = false
    /// What the finished import brought in, read once when it finishes.
    @State private var arrived: [DraftSummary] = []

    private var phase: JournalImportCoordinator.Phase { importer.phase }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch phase {
                    case .idle:
                        Button {
                            picking = true
                        } label: {
                            Label("Choose journal folders", systemImage: "folder.badge.plus")
                        }

                    case .working(let progress):
                        VStack(alignment: .leading, spacing: 8) {
                            if let folder = importer.folder, folder.of > 1 {
                                Text("\(folder.name), \(folder.number) of \(folder.of)")
                                    .font(.subheadline.weight(.semibold))
                            }
                            ProgressView(value: progress.fraction)
                            Text(progress.readTotal == 0
                                 ? "Opening the folder\u{2026}"
                                 : progress.isReading
                                 ? "Getting entries from iCloud: \(progress.readDone) of \(progress.readTotal)"
                                 : "\(progress.entriesDone) of \(progress.entriesTotal) entries, \(progress.filesDone) of \(progress.filesTotal) photos and videos")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("You can close this or leave the app. The import keeps going, with its progress on the Lock Screen.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                    case .done(let report):
                        Label(headline(report), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.reached)
                        reportRows(report)
                        Button {
                            importer.reset()
                            picking = true
                        } label: {
                            Label("Import another folder", systemImage: "folder.badge.plus")
                        }

                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.failed)
                    }
                } footer: {
                    Text("Pick the folders an export produced, as many as you like, or the one folder that holds them all. Each is imported in turn. If you have the zip, uncompress it in Files first, then choose the folder inside.\n\nFastest for a big journal: plug this iPhone into your Mac, open it in Finder, and drag the folders onto DumpNotes under Files. Then choose them here from On My iPhone, DumpNotes. Nothing has to download from iCloud.\n\nNothing on this phone is removed. An entry already here is skipped, or brought up to date when the folder has a newer version, keeping anything you have written in it since. Importing the same folders twice is safe.")
                }
                // What came in, so an import is something you can look through rather than a
                // number. Each opens the entry.
                if !arrived.isEmpty {
                    Section("Brought in") {
                        ForEach(arrived) { entry in
                            NavigationLink {
                                EntryScreen(id: entry.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).lineLimit(1)
                                    Text(entry.mediaCount == 0
                                         ? entry.shortDate
                                         : "\(entry.shortDate) \u{00B7} \(entry.mediaCount) \(entry.mediaCount == 1 ? "photo" : "photos")")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: phase, initial: true) { _, now in
                guard case .done(let report) = now, let store = services.store else {
                    arrived = []
                    return
                }
                arrived = report.importedIds.compactMap { try? store.draft(id: $0) }.map(DraftSummary.init)
            }
            .navigationTitle("Import a journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(phase == .idle ? "Cancel" : "Done") {
                        importer.reset()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $picking,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importer.start(urls)
                case .failure:
                    // Cancelling is a `.failure` on some paths and is not an error.
                    break
                }
            }
        }
    }

    private func headline(_ report: DraftStore.ImportReport) -> String {
        if report.added == 0 && report.attachments > 0 {
            let noun = report.attachments == 1 ? "photo" : "photos"
            return "Added \(report.attachments) \(noun) to entries already here"
        }
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
        if report.updated > 0 {
            row("Brought up to date", "\(report.updated)", Brand.muted)
        }
        if report.additionsWaiting > 0 {
            // Not a problem: those entries' year hasn't been imported, and it brings them.
            row("For entries not imported yet", "\(report.additionsWaiting)", Brand.muted)
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
}
