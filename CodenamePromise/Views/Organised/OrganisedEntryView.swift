import CodenamePromiseCore
import SwiftUI

/// The arranged entry, with the words behind it one tap away.
///
/// An app that rewrites your day and shows you only its version is asking for a kind of trust
/// no product has earned. The same app that lets you open any section and read the sentences
/// it was built from has earned it cheaply, and the mapping is already there: the server
/// verifies that every line is accounted for and sends back the citations that prove it.
///
/// So the disclosure is not a debugging affordance. It is the feature that makes an
/// AI-arranged journal credible instead of unnerving, and it is why `sources` is carried all
/// the way from the model to this view rather than discarded after the guard has run.
struct OrganisedEntryView: View {
    let organised: OrganisedEntry
    /// Shown when the arrangement was built from words that have since changed.
    var isStale: Bool = false

    @State private var revealed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isStale {
                staleNotice
            }

            ForEach(organised.sections) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.heading)
                        .font(Type.label(15, .semibold))
                        .foregroundStyle(Brand.violet)

                    SectionBody(text: section.body)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if revealed.contains(section.id) {
                                revealed.remove(section.id)
                            } else {
                                revealed.insert(section.id)
                            }
                        }
                        Haptics.picked()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: revealed.contains(section.id)
                                  ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                            Text(revealed.contains(section.id)
                                 ? "Hide what you said"
                                 : "What you said (\(section.sources.count))")
                        }
                        .font(Type.caption(11.5, .medium))
                        .foregroundStyle(Brand.muted)
                    }
                    .buttonStyle(.pressable)

                    if revealed.contains(section.id) {
                        spokenLines(for: section)
                    }
                }
            }

            if !organised.dropped.isEmpty {
                droppedNotice
            }
        }
    }

    /// The transcript lines this section was built from, in the order they were spoken.
    private func spokenLines(for section: OrganisedEntry.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(organised.spokenLines(for: section).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Type.journal(13.5))
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 11)
        .overlay(alignment: .leading) {
            // A quiet rule rather than a box: these are the same words, not a different kind
            // of thing, and boxing them would make them look like a quotation from elsewhere.
            Rectangle().fill(Brand.edge).frame(width: 2)
        }
        .padding(.top, 2)
    }

    /// Says plainly what was left out, because a count nobody can inspect is worse than none.
    private var droppedNotice: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(organised.dropped, id: \.self) { index in
                    if index >= 1, index <= organised.sentences.count {
                        Text(organised.sentences[index - 1])
                            .font(Type.journal(13))
                            .foregroundStyle(Brand.muted.opacity(0.8))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("\(organised.dropped.count) filler \(organised.dropped.count == 1 ? "line" : "lines") left out")
                .font(Type.caption(11.5))
                .foregroundStyle(Brand.muted)
        }
        .tint(Brand.muted)
    }

    private var staleNotice: some View {
        Label(
            "You've said more since this was arranged.",
            systemImage: "arrow.triangle.2.circlepath"
        )
        .font(Type.caption(11.5, .medium))
        .foregroundStyle(Brand.waiting)
    }
}

/// A section's body, rendered the way it will leave the app.
///
/// `Text` does not parse markdown from a `String`, so a bullet arrived on screen as a literal
/// "- " while the exported version became a real list in Notion. The view and the export
/// disagreed about the same entry, and the view was the one you could not check.
///
/// Lines are handled rather than the whole block, because `AttributedString(markdown:)`
/// flattens lists into one paragraph — it does inline emphasis well and block structure not
/// at all, which is the opposite of what is needed here. Indentation comes from the leading
/// whitespace the writer used, so a nested point looks nested.
private struct SectionBody: View {
    let text: String

    private struct Line: Identifiable {
        let id = UUID()
        let content: String
        let bulletDepth: Int?
    }

    private var lines: [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                return Line(
                    content: String(trimmed.dropFirst(marker.count)),
                    // Two spaces per level is the markdown convention, and anything deeper
                    // than three levels in a journal entry is a mistake rather than a nest.
                    bulletDepth: min(indent / 2, 3)
                )
            }
            return Line(content: trimmed, bulletDepth: nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines.filter { !$0.content.isEmpty }) { line in
                if let depth = line.bulletDepth {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}")
                            .font(Type.journal(16))
                            .foregroundStyle(Brand.violet)
                        inline(line.content)
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                } else {
                    inline(line.content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown only — bold and italic, which a writer's own emphasis may produce.
    /// Falls back to the plain string rather than showing asterisks if it cannot be parsed.
    private func inline(_ content: String) -> some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
            } else {
                Text(content)
            }
        }
        .font(Type.journal(16))
        .foregroundStyle(Brand.ink)
        .lineSpacing(5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
