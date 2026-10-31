import CodenamePromiseCore
import SwiftUI

/// Exactly what the inbox just added, entry by entry.
///
/// "Added 6 photos and a note to 5 entries" says that something happened, not what. This
/// shows each entry that changed, the note in full as it went in, and the photos it gained,
/// with a way straight into the entry to check it.
struct InboxDigestView: View {
    let digest: CaptureIngestor.Outcome
    let store: DraftStore
    let fileStore: MediaFileStore
    let onOpen: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Plain values, read once. Rows used to hold the photos' models and be re-read from the
    /// store on every redraw; a photo deleted while the sheet was up then trapped the moment
    /// a row touched it (ADR-009a).
    private struct Row: Identifiable {
        let id: UUID
        let day: CalendarDay
        let title: String
        let added: CaptureIngestor.Outcome.Added
        let media: [DraftSummary.Thumb]
    }

    @State private var rows: [Row]?

    /// Newest day first, the same order as the entry list.
    private func readRows() -> [Row] {
        digest.added.compactMap { id, added -> Row? in
            guard let draft = try? store.draft(id: id) else { return nil }
            let media = added.mediaIds.compactMap { try? store.mediaItem(id: $0) }.map {
                DraftSummary.Thumb(id: $0.id, relativePath: $0.relativePath, isVideo: $0.kind == .video)
            }
            return Row(id: id, day: draft.entryDate, title: title(of: draft), added: added, media: media)
        }
        .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                let rows = rows ?? []
                if self.rows != nil, rows.isEmpty {
                    EmptyState("Nothing to show", message: "The entries these went into have since been deleted.", mood: .puzzled)
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 24)
                }
                ForEach(rows) { row in
                    Section {
                        if !row.media.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 6) {
                                    ForEach(row.media) { thumb in
                                        PhotoTile(thumb: thumb, fileStore: fileStore, maxPixel: 216)
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .frame(height: 76)
                        }

                        ForEach(Array(row.added.notes.enumerated()), id: \.offset) { _, note in
                            Text(note)
                                .font(Type.journal(16))
                                .foregroundStyle(Brand.ink)
                                .textSelection(.enabled)
                                .padding(.vertical, 2)
                        }

                        if row.added.recordings > 0 {
                            Label(
                                row.added.recordings == 1 ? "1 recording, transcribed into the entry" : "\(row.added.recordings) recordings, transcribed into the entry",
                                systemImage: "waveform"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }

                        Button {
                            onOpen(row.id)
                        } label: {
                            Label("Open entry", systemImage: "arrow.right.circle")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Brand.violet)
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.day.representativeDate().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                                .textCase(nil)
                            Text(row.title)
                                .font(.footnote)
                                .textCase(nil)
                                .lineLimit(1)
                        }
                    } footer: {
                        Text(summary(of: row))
                    }
                }
            }
            .onAppear { if rows == nil { rows = readRows() } }
            .navigationTitle("Added from your inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func summary(of row: Row) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : (n == 1 ? "1 \(one)" : "\(n) \(many)")
        }
        let parts = [
            count(row.added.notes.count, "note", "notes"),
            count(row.media.filter { !$0.isVideo }.count, "photo", "photos"),
            count(row.media.filter { $0.isVideo }.count, "video", "videos"),
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "" }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "Added \(list)."
    }

    private func title(of draft: EntryDraft) -> String {
        if let title = draft.content.title, !title.isEmpty { return title }
        let firstLine = draft.content.rawText
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        return firstLine.map { String($0.prefix(50)) } ?? "Untitled entry"
    }
}
