import CodenamePromiseCore
import SwiftData
import SwiftUI

/// Search the journal: what you wrote, the words in your photos, and what your photos show.
/// Each kind of match has its own section, so it's clear why something came up.
struct SearchView: View {
    let search: SearchCoordinator
    let store: DraftStore
    let fileStore: MediaFileStore
    /// Opens an entry; the sheet closes first.
    let onOpen: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results = SearchIndex.Results()
    @State private var limitedToDay = false
    @State private var day = Date()
    /// The photos found, by id, for their thumbnails.
    @State private var media: [UUID: DraftSummary.Thumb] = [:]
    @State private var viewing: ViewingPhoto?

    private struct ViewingPhoto: Identifiable {
        let items: [MediaItem]
        let id: UUID
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Only one day", isOn: $limitedToDay.animation())
                    if limitedToDay {
                        DatePicker("Day", selection: $day, displayedComponents: .date)
                    }
                }
                if search.readingPhotos, search.photosTotal > 0, search.photosRead < search.photosTotal {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: Double(search.photosRead), total: Double(search.photosTotal))
                            Text("Reading photos: \(search.photosRead.formatted()) of \(search.photosTotal.formatted()). Photos not read yet won't show up in results.")
                                .font(Type.caption(12))
                                .foregroundStyle(Brand.muted)
                        }
                    }
                }
                if trimmed.isEmpty {
                    Section {
                    } footer: {
                        Text("Finds what you wrote, words in your photos (signs, pages, screenshots), and what your photos show, like \u{201C}tree\u{201D}, \u{201C}beach\u{201D} or \u{201C}dog\u{201D}. Everything is read on this phone.")
                    }
                } else if results.isEmpty {
                    Section {
                        Text("Nothing found for \u{201C}\(trimmed)\u{201D}\(limitedToDay ? " on that day" : "")")
                            .foregroundStyle(Brand.muted)
                    }
                } else {
                    if !results.entries.isEmpty { writingSection }
                    if !results.photoText.isEmpty {
                        photoSection("Words in photos", symbol: "text.viewfinder", hits: results.photoText, quotes: true)
                    }
                    if !results.photoContents.isEmpty {
                        photoSection("In photos", symbol: "photo", hits: results.photoContents, quotes: false)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Words, or what's in a photo")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task(id: SearchKey(query: trimmed, day: dayKey)) { await run() }
            // Photos read while the screen is open join the results.
            .onChange(of: search.photosRead / 24) { _, _ in Task { await run() } }
            .onAppear { search.refresh() }
            .fullScreenCover(item: $viewing) { viewing in
                MediaViewer(items: viewing.items, fileStore: fileStore, selection: viewing.id)
            }
        }
    }

    private struct SearchKey: Equatable { let query: String; let day: String? }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dayKey: String? { limitedToDay ? CalendarDay(date: day).rawValue : nil }

    private func run() async {
        guard !trimmed.isEmpty else { results = .init(); return }
        // A short pause so each keystroke doesn't search.
        try? await Task.sleep(for: .milliseconds(150))
        if Task.isCancelled { return }
        let found = await search.index.search(trimmed, day: dayKey)
        if Task.isCancelled { return }
        results = found
        loadThumbs(Set((found.photoText + found.photoContents).map(\.mediaId)))
    }

    private func loadThumbs(_ ids: Set<UUID>) {
        let missing = Array(ids.subtracting(media.keys))
        guard !missing.isEmpty,
              let items = try? store.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { missing.contains($0.id) }))
        else { return }
        for item in items {
            media[item.id] = DraftSummary.Thumb(id: item.id, relativePath: item.relativePath, isVideo: item.kind == .video)
        }
    }

    // MARK: - Sections

    private var writingSection: some View {
        Section {
            ForEach(results.entries) { hit in
                Button {
                    open(hit.draftId)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(hit.title.isEmpty ? "Untitled entry" : hit.title)
                                .font(Type.label(15))
                                .foregroundStyle(Brand.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(dayLabel(hit.day))
                                .font(Type.caption(12))
                                .foregroundStyle(Brand.muted)
                        }
                        if !hit.snippet.isEmpty {
                            highlighted(hit.snippet)
                                .font(Type.body(14))
                                .foregroundStyle(Brand.muted)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            header("In your writing", symbol: "text.alignleft", count: results.entries.count)
        }
    }

    private func photoSection(_ title: String, symbol: String, hits: [SearchIndex.MediaHit], quotes: Bool) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 12) {
                ForEach(hits) { hit in
                    Button {
                        showPhoto(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Group {
                                if let thumb = media[hit.mediaId] {
                                    PhotoTile(thumb: thumb, fileStore: fileStore, maxPixel: 312)
                                } else {
                                    Brand.panel
                                }
                            }
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(dayLabel(hit.day))
                                .font(Type.caption(11.5))
                                .foregroundStyle(Brand.ink)
                            Text(quotes ? "\u{201C}\(hit.snippet)\u{201D}" : hit.snippet)
                                .font(Type.caption(11))
                                .foregroundStyle(Brand.muted)
                                .lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open entry", systemImage: "doc.text") { open(hit.draftId) }
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            header(title, symbol: symbol, count: hits.count)
        }
    }

    private func header(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            // The index returns at most 200 of each kind.
            Text(count >= 200 ? "200+" : count.formatted()).monospacedDigit()
        }
    }

    /// The words searched for, in bold, wherever they start a word in the snippet.
    private func highlighted(_ snippet: String) -> Text {
        var text = AttributedString(snippet)
        let terms = trimmed.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for term in terms {
            var from = snippet.startIndex
            while let found = snippet.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<snippet.endIndex) {
                if let range = Range(found, in: text) {
                    text[range].font = .system(size: 14, weight: .semibold)
                    text[range].foregroundColor = Brand.ink
                }
                from = found.upperBound
            }
        }
        return Text(text)
    }

    private func dayLabel(_ key: String) -> String {
        guard let day = CalendarDay(rawValue: key) else { return key }
        return day.representativeDate().formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func open(_ id: UUID) {
        dismiss()
        onOpen(id)
    }

    /// Full screen, swiping through the other photos found.
    private func showPhoto(_ hit: SearchIndex.MediaHit) {
        let ids = (results.photoText + results.photoContents).map(\.mediaId)
        guard let items = try? store.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))
        else { return }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let ordered = ids.filter { seen.insert($0).inserted }.compactMap { byId[$0] }
        viewing = ViewingPhoto(items: ordered, id: hit.mediaId)
    }
}
