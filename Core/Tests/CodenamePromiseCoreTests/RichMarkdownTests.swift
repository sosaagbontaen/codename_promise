import Foundation
import Testing

@testable import CodenamePromiseCore

/// The editor is rich, the storage is Markdown. These pin the round trip: whatever the editor
/// can make reads back exactly, and plain entries written before it read as themselves.
@Suite("Rich Markdown")
struct RichMarkdownTests {
    typealias Doc = RichDocument
    typealias Run = RichDocument.Run
    typealias Style = RichDocument.Style

    private func roundTrips(_ doc: Doc, sourceLocation: SourceLocation = #_sourceLocation) {
        let markdown = doc.markdown
        #expect(Doc(markdown: markdown) == doc, "\(markdown)", sourceLocation: sourceLocation)
    }

    @Test func plainTextReadsAsItself() {
        let text = "Went for a run.\nSaw Aidan at the park.\n\nLong day."
        let doc = Doc(markdown: text)
        #expect(doc.blocks.count == 4)
        #expect(doc.blocks.allSatisfy { $0.kind == .paragraph })
        #expect(doc.markdown == text)
        #expect(doc.plainText == text)
    }

    @Test func existingDashesBecomeBulletsAndStayDashes() {
        let text = "- one\n  - nested\n- two"
        let doc = Doc(markdown: text)
        #expect(doc.blocks.map(\.kind) == [.bullet, .bullet, .bullet])
        #expect(doc.blocks.map(\.indent) == [0, 1, 0])
        #expect(doc.markdown == text)
    }

    @Test func everyBlockKindRoundTrips() {
        roundTrips(Doc(blocks: [
            .init(kind: .heading(level: 1, toggle: false), runs: [Run("Title")]),
            .init(kind: .heading(level: 3, toggle: false), runs: [Run("Small")]),
            .init(kind: .bullet, indent: 1, runs: [Run("point")]),
            .init(kind: .numbered, runs: [Run("first")]),
            .init(kind: .check(done: false), runs: [Run("todo")]),
            .init(kind: .check(done: true), indent: 2, runs: [Run("done")]),
            .init(kind: .quote, runs: [Run("said")]),
            .init(kind: .paragraph, runs: [Run("plain")]),
        ]))
    }

    @Test func everyInlineStyleRoundTrips() {
        roundTrips(Doc(blocks: [.init(runs: [
            Run("a ", Style()),
            Run("bold", Style(bold: true)),
            Run(" ", Style()),
            Run("both", Style(bold: true, italic: true)),
            Run(" ", Style()),
            Run("under", Style(underline: true)),
            Run("struck", Style(strike: true)),
            Run("red big", Style(color: "#e5534b", size: 1.5)),
            Run("marked", Style(highlight: "#fff3a0")),
            Run("site", Style(bold: true, link: "https://example.com")),
        ])]))
    }

    @Test func punctuationThatLooksLikeMarkupSurvives() {
        let doc = Doc(blocks: [
            .init(runs: [Run("2*3 = 6, a_b, ~tilde~, [not a link], <tag>, back\\slash")]),
            .init(runs: [Run("- not a bullet")]),
            .init(runs: [Run("# not a heading")]),
            .init(runs: [Run("12. not a list")]),
        ])
        roundTrips(doc)
        #expect(Doc(markdown: doc.markdown).blocks.allSatisfy { $0.kind == .paragraph })
    }

    @Test func openAndFoldedTogglesRoundTrip() {
        let open = Doc(blocks: [
            .init(kind: .heading(level: 2, toggle: true), runs: [Run("Trip")]),
            .init(kind: .bullet, runs: [Run("beach")]),
            .init(kind: .heading(level: 2, toggle: false), runs: [Run("After")]),
        ])
        roundTrips(open)
        #expect(open.markdown.contains("<details open>"))

        let folded = Doc(blocks: [
            .init(kind: .heading(level: 2, toggle: true), runs: [Run("Trip")],
                  folded: [.init(kind: .bullet, runs: [Run("hidden but kept")])]),
            .init(kind: .paragraph, runs: [Run("outside")]),
        ])
        roundTrips(folded)
        // Folded words are still words.
        #expect(folded.plainText.contains("hidden but kept"))
    }

    @Test func plainTextDropsMarkupButKeepsWords() {
        let markdown = "## Day\n- **Ran** <u>five</u> <span style=\"color:#e5534b\">miles</span>\n- [x] [called](https://x.y) mom"
        #expect(Doc.plainText(ofMarkdown: markdown) == "Day\n- Ran five miles\n- [x] called mom")
    }

    @Test func unmatchedMarkersStayLiteral() {
        let doc = Doc(markdown: "5 * 3 and a lone ** here")
        #expect(doc.blocks.first?.text == "5 * 3 and a lone ** here")
    }

    /// Thousands of random documents, every style and awkward character, must come back
    /// exactly. The editor saves on every keystroke, so a lossy edge case would eat words.
    @Test func randomDocumentsRoundTrip() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abc XYZ 123 *_~[]<>\\`#-.!?()é😀")
        let kinds: [Doc.Kind] = [.paragraph, .heading(level: 1, toggle: false), .heading(level: 2, toggle: false),
                                 .bullet, .numbered, .check(done: true), .check(done: false), .quote]
        for _ in 0..<3000 {
            var blocks: [Doc.Block] = []
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                var runs: [Run] = []
                for _ in 0..<Int.random(in: 1...3, using: &rng) {
                    let text = String((0..<Int.random(in: 1...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                    var style = Style()
                    style.bold = Bool.random(using: &rng)
                    style.italic = Bool.random(using: &rng)
                    style.underline = Int.random(in: 0..<4, using: &rng) == 0
                    style.strike = Int.random(in: 0..<4, using: &rng) == 0
                    if Int.random(in: 0..<5, using: &rng) == 0 { style.color = "#e5534b" }
                    if Int.random(in: 0..<6, using: &rng) == 0 { style.size = 1.25 }
                    if Int.random(in: 0..<6, using: &rng) == 0 { style.link = "https://example.com/a" }
                    runs.append(Run(text, style))
                }
                let kind = kinds.randomElement(using: &rng)!
                var indent = 0
                if case .heading = kind {} else { indent = Int.random(in: 0...2, using: &rng) }
                blocks.append(.init(kind: kind, indent: indent, runs: runs))
            }
            let doc = Doc(blocks: blocks)
            let back = Doc(markdown: doc.markdown)
            // Compare text and styles character by character; how runs split is free to differ.
            #expect(back.blocks.count == doc.blocks.count, "\(doc.markdown)")
            guard back.blocks.count == doc.blocks.count else { return }
            for (a, b) in zip(doc.blocks, back.blocks) {
                #expect(a.kind == b.kind && a.indent == b.indent, "\(doc.markdown)")
                let expand = { (block: Doc.Block) in block.runs.flatMap { run in run.text.map { ($0, run.style) } } }
                let left = expand(a), right = expand(b)
                #expect(left.map(\.0) == right.map(\.0), "\(doc.markdown)")
                #expect(left.map(\.1) == right.map(\.1), "styles: \(doc.markdown)")
                if left.map(\.0) != right.map(\.0) || left.map(\.1) != right.map(\.1) { return }
            }
        }
    }
}
