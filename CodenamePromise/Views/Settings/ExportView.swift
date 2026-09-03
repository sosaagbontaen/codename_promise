import CodenamePromiseCore
import SwiftUI
import UniformTypeIdentifiers

/// Getting the whole journal out, as files.
///
/// Deliberately not buried: this is the answer to "what happens if I lose my phone", and a
/// backup nobody can find is not a backup. It writes a folder of markdown plus media, zips
/// it, and hands it to the share sheet so it can go to Files, iCloud Drive, or anywhere else
/// the person already trusts.
struct ExportView: View {
    let store: DraftStore
    let fileStore: MediaFileStore
    /// Nil exports the whole journal. A selection exports only those entries, in the order
    /// they were picked.
    ///
    /// All-or-nothing is right for a backup and wrong for the other half of what people do
    /// with an export: sending one trip, or one month, to somebody. The writer always took an
    /// array; only the caller insisted on handing it everything.
    var selection: [UUID]? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case working
        case ready(URL, JournalExporter.Summary)
        case failed(String)
    }

    private var headerTitle: String {
        guard let selection, !selection.isEmpty else { return "Your whole journal, as files" }
        return "The entries you picked, as files"
    }

    private var exportTitle: String {
        guard let selection, !selection.isEmpty else { return "Export everything" }
        return selection.count == 1 ? "Export this entry" : "Export these \(selection.count) entries"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch phase {
                    case .idle:
                        Button {
                            Task { await run() }
                        } label: {
                            Label(exportTitle, systemImage: "square.and.arrow.up.on.square")
                        }

                    case .working:
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Writing your journal out\u{2026}")
                        }

                    case .ready(let url, let summary):
                        ShareLink(item: url) {
                            Label("Save or send the export", systemImage: "square.and.arrow.up")
                        }
                        summaryRows(summary)

                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.failed)
                        Button("Try again") { Task { await run() } }
                    }
                } header: {
                    Text(headerTitle)
                } footer: {
                    Text("One markdown file per entry, named by its day, with photos and videos beside it. Recordings that were never transcribed come too, because their words exist nowhere else. Nothing in the export needs this app to read it.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryRows(_ summary: JournalExporter.Summary) -> some View {
        LabeledContent("Entries", value: "\(summary.entries)")
        if summary.mediaFiles > 0 {
            LabeledContent("Photos and videos", value: "\(summary.mediaFiles)")
        }
        if summary.audioFiles > 0 {
            LabeledContent("Recordings not yet transcribed", value: "\(summary.audioFiles)")
        }
        if !summary.isCompleteRecord {
            // Never silent about an incomplete archive: a backup you wrongly believe is
            // whole is worse than none.
            Label(
                "\(summary.missingFiles.count) attachment\(summary.missingFiles.count == 1 ? "" : "s") couldn't be found. Everything else was exported, and the details are in the README.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(Brand.waiting)
        }
    }

    private func run() async {
        phase = .working
        do {
            let stamp = Date().formatted(.iso8601.year().month().day())
            let name = "\(Bundle.main.appDisplayName) Export \(stamp)"
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
            let folder = staging.appendingPathComponent(name, isDirectory: true)

            let summary: JournalExporter.Summary
            if let selection, !selection.isEmpty {
                summary = try store.export(ids: selection, to: folder, fileStore: fileStore)
            } else {
                summary = try store.exportAll(to: folder, fileStore: fileStore)
            }
            let zipped = try Self.zip(folder, named: name, in: staging)
            phase = .ready(zipped, summary)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Zips a directory using `NSFileCoordinator`'s `.forUploading` reading intent, which is
    /// the system's own archiver &mdash; no third-party dependency for something this
    /// central. The coordinator hands over a temporary zip that it deletes when the block
    /// returns, so it is copied somewhere stable first.
    private static func zip(_ directory: URL, named name: String, in staging: URL) throws -> URL {
        var coordinatorError: NSError?
        var result: Result<URL, Error>?

        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: [.forUploading], error: &coordinatorError
        ) { temporary in
            do {
                let destination = staging.appendingPathComponent("\(name).zip")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: temporary, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(error)
            }
        }

        if let coordinatorError { throw coordinatorError }
        switch result {
        case .success(let url): return url
        case .failure(let error): throw error
        case nil: throw CocoaError(.fileWriteUnknown)
        }
    }
}

extension Bundle {
    /// The name the app actually shows, so copy doesn't hard-code a product name that is
    /// still being decided.
    var appDisplayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Journal"
    }
}
