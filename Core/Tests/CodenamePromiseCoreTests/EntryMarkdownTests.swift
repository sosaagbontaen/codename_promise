import Foundation
import Testing
@testable import CodenamePromiseCore

/// What lands in somebody else's notes app.
///
/// This is the app's answer to "I already use Bear", so the bar is that the result reads like
/// a note a person wrote, not like a database row that escaped.
@Suite("Entry markdown")
struct EntryMarkdownTests {

    private let day = CalendarDay(rawValue: "2026-08-22")!

    private func organised(_ sections: [(String, String)]) -> OrganisedEntry {
        OrganisedEntry(
            sentences: ["one", "two"],
            sections: sections.map {
                OrganisedEntry.Section(heading: $0.0, body: $0.1, sources: [0])
            },
            dropped: [],
            version: "test"
        )
    }

    @Test("the sections become headings")
    func sectionsBecomeHeadings() {
        let out = EntryMarkdown.render(
            title: "A day",
            day: day,
            organised: organised([("Work", "The deploy went out."), ("Home", "Mum called.")]),
            text: "ignored"
        )
        #expect(out.contains("# A day"))
        #expect(out.contains("## Work\n\nThe deploy went out."))
        #expect(out.contains("## Home\n\nMum called."))
    }

    /// The organised entry is the thing the app made. Sending the raw ramble instead would
    /// be sending the input rather than the output.
    @Test("organised text is preferred over the raw words")
    func prefersOrganised() {
        let out = EntryMarkdown.render(
            title: nil, day: day,
            organised: organised([("Work", "Tidy.")]),
            text: "um so anyway the thing"
        )
        #expect(out.contains("Tidy."))
        #expect(!out.contains("um so anyway"))
    }

    @Test("an entry with nothing organised sends what was written")
    func fallsBackToText() {
        let out = EntryMarkdown.render(
            title: nil, day: day, organised: nil, text: "Just a line."
        )
        #expect(out.contains("Just a line."))
    }

    /// None of the archive machinery belongs in a note. Front matter is the specific thing
    /// that makes a pasted export look like a leaked file.
    @Test("no front matter, no ids, no media links")
    func noArchiveMachinery() {
        let out = EntryMarkdown.render(
            title: "A day", day: day, organised: organised([("Work", "Tidy.")]), text: ""
        )
        #expect(!out.contains("---"))
        #expect(!out.contains("id:"))
        #expect(!out.contains("!["))
    }

    @Test("an untitled entry is named after its day, never Untitled")
    func neverUntitled() {
        #expect(EntryMarkdown.heading(title: nil, day: day).contains("Saturday"))
        #expect(EntryMarkdown.heading(title: "   ", day: day).contains("Saturday"))
        #expect(!EntryMarkdown.heading(title: nil, day: day).contains("Untitled"))
    }

    @Test("the filename sorts by day and survives a file system")
    func filename() {
        let name = EntryMarkdown.filename(title: "Work/Life: notes", day: day)
        #expect(name.hasPrefix("2026-08-22"))
        #expect(name.hasSuffix(".md"))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test("the date is always present, even when the title is not the date")
    func dateAlwaysThere() {
        let out = EntryMarkdown.render(
            title: "A day", day: day, organised: nil, text: "x"
        )
        #expect(out.contains("August"))
    }
}
