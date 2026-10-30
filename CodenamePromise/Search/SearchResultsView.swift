import CodenamePromiseCore
import SwiftData
import SwiftUI

/// Results under the journal's search bar, updating as you type. Each kind of match has its
/// own section, so it's clear why something came up.
struct SearchResultsView: View {
    let search: SearchCoordinator
    let store: DraftStore
    let fileStore: MediaFileStore
    let query: String
    let filter: SearchFilter
    /// Opens an entry; with the words to find in it, for a match in its writing.
    let onOpen: (UUID, String?) -> Void

    @State private var results = SearchIndex.Results()
    /// The photos found, by id, for their thumbnails.
    @State private var thumbs: [UUID: DraftSummary.Thumb] = [:]
    @State private var viewing: ViewingPhoto?

    private struct ViewingPhoto: Identifiable {
        let items: [MediaItem]
        let id: UUID
    }

    private struct SearchKey: Equatable {
        let query: String
        let filter: SearchFilter
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showsWriting: Bool { filter.show == .all || filter.show == .writing }
    private var showsPhotoText: Bool { filter.show == .all || filter.show == .photoText }
    private var showsPhotoContents: Bool { filter.show == .all || filter.show == .photoContents }

    private var nothingShown: Bool {
        (!showsWriting || results.entries.isEmpty)
            && (!showsPhotoText || results.photoText.isEmpty)
            && (!showsPhotoContents || results.photoContents.isEmpty)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if search.readingPhotos, search.photosTotal > 0, search.photosRead < search.photosTotal {
                    readingProgress
                }
                if trimmed.isEmpty {
                    Text("Search what you wrote, words in your photos (signs, pages, screenshots), and what your photos show, like \u{201C}tree\u{201D}, \u{201C}beach\u{201D} or \u{201C}dog\u{201D}. Everything is read on this phone.")
                        .font(Type.body(14))
                        .foregroundStyle(Brand.muted)
                        .padding(.top, 8)
                } else if nothingShown {
                    Text("Nothing found for \u{201C}\(trimmed)\u{201D}\(filter.isActive ? " with these filters" : "").")
                        .font(Type.body(15))
                        .foregroundStyle(Brand.muted)
                        .padding(.top, 8)
                } else {
                    if showsWriting, !results.entries.isEmpty { writingSection }
                    if showsPhotoText, !results.photoText.isEmpty {
                        photoSection("Words in photos", symbol: "text.viewfinder", hits: results.photoText, quotes: true)
                    }
                    if showsPhotoContents, !results.photoContents.isEmpty {
                        photoSection("In photos", symbol: "photo", hits: results.photoContents, quotes: false)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Brand.ground)
        .task(id: SearchKey(query: trimmed, filter: filter)) { await run() }
        // Photos read while searching join the results.
        .onChange(of: search.photosRead / 24) { _, _ in Task { await run(debounce: false) } }
        .onAppear { search.refresh() }
        .fullScreenCover(item: $viewing) { viewing in
            MediaViewer(items: viewing.items, fileStore: fileStore, selection: viewing.id)
        }
    }

    private func run(debounce: Bool = true) async {
        guard !trimmed.isEmpty else { results = .init(); return }
        // A short pause so each keystroke doesn't search.
        if debounce { try? await Task.sleep(for: .milliseconds(150)) }
        if Task.isCancelled { return }
        let range = filter.dayRange()
        let found = await search.index.search(trimmed, from: range.from, to: range.to, newestFirst: filter.newestFirst)
        if Task.isCancelled { return }
        results = found
        loadThumbs(Set((found.photoText + found.photoContents).map(\.mediaId)))
    }

    private func loadThumbs(_ ids: Set<UUID>) {
        let missing = Array(ids.subtracting(thumbs.keys))
        guard !missing.isEmpty,
              let items = try? store.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { missing.contains($0.id) }))
        else { return }
        for item in items {
            thumbs[item.id] = DraftSummary.Thumb(id: item.id, relativePath: item.relativePath, isVideo: item.kind == .video)
        }
    }

    // MARK: - Sections

    /// How far photo reading has got, and a way to finish it in one go.
    private var readingProgress: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(search.photosRead), total: Double(search.photosTotal))
                    .tint(Brand.violet)
                Text(search.finishing
                     ? "Reading \(search.photosRead.formatted()) of \(search.photosTotal.formatted()) photos. You can leave the app."
                     : "\(search.photosRead.formatted()) of \(search.photosTotal.formatted()) photos searchable so far")
                    .font(Type.caption(12))
                    .foregroundStyle(Brand.muted)
            }
            if !search.finishing {
                Button("Finish now") {
                    Task { await search.finishNow() }
                }
                .font(Type.label(13, .semibold))
                .buttonStyle(.borderedProminent)
                .tint(Brand.violet)
                .controlSize(.small)
            }
        }
    }

    private var writingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("In your writing", symbol: "text.alignleft", count: results.entries.count)
            VStack(spacing: 0) {
                ForEach(Array(results.entries.enumerated()), id: \.element.id) { index, hit in
                    if index > 0 { Divider().padding(.leading, 16) }
                    Button {
                        onOpen(hit.draftId, trimmed)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
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
                                highlighted(hit.snippet.replacingOccurrences(of: "\n", with: " "))
                                    .font(Type.body(14))
                                    .foregroundStyle(Brand.muted)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.row)
                }
            }
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func photoSection(_ title: String, symbol: String, hits: [SearchIndex.MediaHit], quotes: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(title, symbol: symbol, count: hits.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 12) {
                ForEach(hits) { hit in
                    Button {
                        showPhoto(hit)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Group {
                                if let thumb = thumbs[hit.mediaId] {
                                    PhotoTile(thumb: thumb, fileStore: fileStore, maxPixel: 312)
                                } else {
                                    Brand.panel
                                }
                            }
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(dayLabel(hit.day))
                                .font(Type.caption(11.5))
                                .foregroundStyle(Brand.ink)
                            if !hit.snippet.isEmpty {
                                let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
                                Text(quotes ? "\u{201C}\(snippet)\u{201D}" : snippet)
                                    .font(Type.caption(11))
                                    .foregroundStyle(Brand.muted)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open entry", systemImage: "doc.text") { onOpen(hit.draftId, nil) }
                    }
                }
            }
        }
    }

    private func header(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            // The index returns at most 200 of each kind.
            Text(count >= 200 ? "200+" : count.formatted()).monospacedDigit()
        }
        .font(Type.caption(12.5, .semibold))
        .foregroundStyle(Brand.muted)
        .padding(.horizontal, 4)
    }

    /// The words searched for, in bold, wherever they appear in the snippet.
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

    /// Full screen, swiping through the other photos found.
    private func showPhoto(_ hit: SearchIndex.MediaHit) {
        var ids: [UUID] = []
        if showsPhotoText { ids += results.photoText.map(\.mediaId) }
        if showsPhotoContents { ids += results.photoContents.map(\.mediaId) }
        guard let items = try? store.context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))
        else { return }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let ordered = ids.filter { seen.insert($0).inserted }.compactMap { byId[$0] }
        viewing = ViewingPhoto(items: ordered, id: hit.mediaId)
    }
}
