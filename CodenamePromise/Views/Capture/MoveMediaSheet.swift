import CodenamePromiseCore
import SwiftUI

/// Picks the entry a set of attachments should move to.
///
/// Grouped by day and labelled the way the draft list labels them, because the mistake this
/// fixes is almost always a *day* mistake — photos imported by capture date that landed one
/// day off. Choosing by date is how the user is already thinking about it.
struct MoveMediaSheet: View {
    let count: Int
    let store: DraftStore
    let fileStore: MediaFileStore
    let excluding: UUID
    let onPick: (EntryDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [EntryDraft] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn't load your entries",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if drafts.isEmpty {
                    ContentUnavailableView(
                        "No other entries",
                        systemImage: "tray",
                        description: Text("Create another entry first, then move these here.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Move \(count) item\(count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { reload() }
        }
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.day) { group in
                Section(group.label) {
                    ForEach(group.drafts, id: \.id) { draft in
                        Button {
                            onPick(draft)
                            dismiss()
                        } label: {
                            DestinationRow(draft: draft, fileStore: fileStore)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private struct Group_ {
        let day: String
        let label: String
        let drafts: [EntryDraft]
    }

    private var grouped: [Group_] {
        let buckets = Dictionary(grouping: drafts, by: \.entryDateKey)
        return buckets.keys.sorted(by: >).map { key in
            Group_(
                day: key,
                label: CalendarDay(rawValue: key)?.representativeDate()
                    .formatted(.dateTime.weekday(.wide).month(.wide).day().year()) ?? key,
                drafts: buckets[key] ?? []
            )
        }
    }

    private func reload() {
        do {
            drafts = try store.allDrafts().filter { $0.id != excluding }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// One candidate entry. Shows what it already holds, so "the one with the beach photos" is
/// answerable without opening it.
private struct DestinationRow: View {
    let draft: EntryDraft
    let fileStore: MediaFileStore

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if !draft.orderedMedia.isEmpty {
                    Text("\(draft.orderedMedia.count) attachment\(draft.orderedMedia.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                ForEach(draft.orderedMedia.prefix(3), id: \.id) { item in
                    MoveDestinationThumbnail(item: item, fileStore: fileStore)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        if let title = draft.content.title, !title.isEmpty { return title }
        let firstLine = draft.content.rawText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return firstLine.isEmpty ? "Untitled entry" : firstLine
    }
}

private struct MoveDestinationThumbnail: View {
    let item: MediaItem
    let fileStore: MediaFileStore

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task {
            if image == nil {
                image = await ThumbnailCache.shared.thumbnail(
                    for: item, fileStore: fileStore, maxPixel: 64
                )
            }
        }
    }
}
