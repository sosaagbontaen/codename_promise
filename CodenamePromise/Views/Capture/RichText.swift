import CodenamePromiseCore
import SwiftUI
import UIKit

/// The bridge between the stored document and what the rich editor edits.
///
/// The editor works on an `AttributedString`. Two attributes of our own carry the meaning:
/// every character knows its run's style, and every character knows what kind of line it's
/// on. Everything visible, fonts, colours, the "• " in front of a bullet, is drawn from those
/// two and redrawn after each edit, so the text you see can't drift from what gets saved.
///
/// Line markers (bullets, numbers, checkboxes, quote bars, toggle arrows) are real characters
/// in the editor so the caret behaves naturally around them, and are stripped back off when
/// the text is read into a document.
@available(iOS 26.0, *)
enum RichText {

    // MARK: Attributes

    enum RunStyleKey: AttributedStringKey {
        typealias Value = RichDocument.Style
        static let name = "dn.runStyle"
    }

    struct LineInfo: Hashable, Sendable {
        var kind: RichDocument.Kind = .paragraph
        var indent = 0
        /// A folded toggle heading's tucked-away lines, carried on the heading's characters.
        var folded: [RichDocument.Block]?
    }

    enum LineKey: AttributedStringKey {
        typealias Value = LineInfo
        static let name = "dn.line"
    }

    // MARK: Markers

    static func marker(for block: RichDocument.Block, number: Int) -> String {
        switch block.kind {
        case .paragraph: return ""
        case .heading(_, let toggle): return toggle ? (block.folded == nil ? "▾ " : "▸ ") : ""
        case .bullet: return ["• ", "◦ ", "▪ "][block.indent % 3]
        case .numbered: return "\(number). "
        case .check(let done): return done ? "☑ " : "☐ "
        case .quote: return "▎ "
        }
    }

    /// What can start a line of each kind, complete or partly deleted, so a marker someone
    /// backspaced into is cleared rather than left as a stray character.
    private static func stripMarker(_ text: inout Substring, kind: RichDocument.Kind) -> Bool {
        let patterns: [String]
        switch kind {
        case .paragraph: return true
        case .heading(_, let toggle):
            guard toggle else { return true }
            patterns = ["▾ ", "▸ ", "▾", "▸"]
        case .bullet: patterns = ["• ", "◦ ", "▪ ", "•", "◦", "▪"]
        case .check: patterns = ["☑ ", "☐ ", "☑", "☐"]
        case .quote: patterns = ["▎ ", "▎"]
        case .numbered:
            let digits = text.prefix { $0.isNumber }
            var rest = text.dropFirst(digits.count)
            if rest.hasPrefix(". ") { text = rest.dropFirst(2); return !digits.isEmpty }
            if rest.hasPrefix(".") { rest = rest.dropFirst(); text = rest; return false }
            if !digits.isEmpty { text = rest; return false }
            return false
        }
        for (index, pattern) in patterns.enumerated() where text.hasPrefix(pattern) {
            text = text.dropFirst(pattern.count)
            return index < patterns.count / 2
        }
        return false
    }

    // MARK: Reading the editor

    /// The editor's text as a document. A list line whose marker was deleted becomes a plain
    /// line, which is what backspacing over a bullet should do.
    static func document(from text: AttributedString) -> RichDocument {
        var blocks: [RichDocument.Block] = []
        for line in lines(of: text) {
            let slice = text[line]
            let info = slice.runs.first?[LineKey.self] ?? LineInfo()
            var block = RichDocument.Block(kind: info.kind, indent: 0, runs: [], folded: nil)

            var characters = Substring(String(slice.characters))
            var tabs = 0
            if case .heading = info.kind {} else {
                while characters.first == "\t" { characters = characters.dropFirst(); tabs += 1 }
            }
            let markerCount = characters.count
            if !stripMarker(&characters, kind: info.kind) {
                block.kind = .paragraph
            }
            block.indent = tabs
            if case .heading(_, true) = block.kind { block.folded = info.folded }
            let skip = tabs + (markerCount - characters.count)

            // Runs, minus the tabs and marker at the front.
            var offset = 0
            for run in slice.runs {
                let runText = String(slice[run.range].characters)
                let start = max(0, skip - offset)
                offset += runText.count
                guard start < runText.count else { continue }
                let kept = String(runText.dropFirst(start))
                block.runs.append(RichDocument.Run(kept, run[RunStyleKey.self] ?? RichDocument.Style()))
            }
            block.runs = block.runs.filter { !$0.text.isEmpty }
            blocks.append(block)
        }
        return RichDocument(blocks: blocks)
    }

    /// Each line's range, without its newline. An empty document is one empty line.
    static func lines(of text: AttributedString) -> [Range<AttributedString.Index>] {
        var out: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text.characters[index] == "\n" {
                out.append(start..<index)
                start = text.characters.index(after: index)
            }
            index = text.characters.index(after: index)
        }
        out.append(start..<text.endIndex)
        return out
    }

    // MARK: Drawing the editor

    struct Look {
        var font: JournalFont
        var size: CGFloat = 17
    }

    static func attributed(_ document: RichDocument, look: Look) -> AttributedString {
        var out = AttributedString()
        var numbers: [Int: Int] = [:]
        for (index, block) in document.blocks.enumerated() {
            if index > 0 {
                var newline = AttributedString("\n")
                // Plain, so a line started after a heading isn't one.
                newline[LineKey.self] = LineInfo()
                newline.font = look.font.font(size: look.size, weight: 400)
                out += newline
            }
            if case .numbered = block.kind {
                numbers[block.indent, default: 0] += 1
                numbers = numbers.filter { $0.key <= block.indent }
            } else {
                numbers = [:]
            }
            out += line(block, number: numbers[block.indent] ?? 1, look: look)
        }
        return out
    }

    static func line(_ block: RichDocument.Block, number: Int, look: Look) -> AttributedString {
        var info = LineInfo(kind: block.kind, indent: block.indent, folded: nil)
        if case .heading(_, true) = block.kind { info.folded = block.folded }

        var line = AttributedString()
        let lead: String
        if case .heading = block.kind { lead = marker(for: block, number: number) }
        else { lead = String(repeating: "\t", count: block.indent) + marker(for: block, number: number) }
        if !lead.isEmpty {
            var prefix = AttributedString(lead)
            prefix.font = baseFont(for: block, style: RichDocument.Style(), look: look)
            prefix.foregroundColor = markerColor(for: block)
            line += prefix
        }
        for run in block.runs {
            var piece = AttributedString(run.text)
            piece[RunStyleKey.self] = run.style
            style(&piece, run.style, block: block, look: look)
            line += piece
        }
        line[LineKey.self] = info
        return line
    }

    /// The text colour, so typing straight after a marker isn't tinted by it.
    private static func markerColor(for block: RichDocument.Block) -> Color {
        Brand.ink
    }

    /// What newly typed text on this line should look like.
    static func typingAttributes(for block: RichDocument.Block, look: Look) -> AttributeContainer {
        var piece = AttributedString(" ")
        var plain = block
        plain.runs = []
        piece[RunStyleKey.self] = RichDocument.Style()
        style(&piece, RichDocument.Style(), block: plain, look: look)
        var info = LineInfo(kind: block.kind, indent: block.indent, folded: nil)
        if case .heading(_, true) = block.kind { info.folded = block.folded }
        piece[LineKey.self] = info
        return piece.runs.first?.attributes ?? AttributeContainer()
    }

    static func baseFont(for block: RichDocument.Block, style: RichDocument.Style, look: Look) -> Font {
        var size = look.size
        var weight: CGFloat = style.bold ? 700 : 400
        if case .heading(let level, _) = block.kind {
            size = [28, 23, 20][max(0, min(level - 1, 2))]
            weight = 700
        }
        size *= CGFloat(style.size ?? 1)
        var font = look.font.font(size: size, weight: weight)
        if style.italic { font = font.italic() }
        return font
    }

    static func style(_ piece: inout AttributedString, _ style: RichDocument.Style, block: RichDocument.Block, look: Look) {
        piece.font = baseFont(for: block, style: style, look: look)
        if case .check(true) = block.kind {
            piece.foregroundColor = Brand.muted
            piece.strikethroughStyle = .single
        } else if case .quote = block.kind {
            piece.foregroundColor = Brand.muted
        }
        if let hex = style.color, let color = Color(hex: hex) { piece.foregroundColor = color }
        if let hex = style.highlight, let color = Color(hex: hex) { piece.backgroundColor = color }
        if style.underline { piece.underlineStyle = .single }
        if style.strike { piece.strikethroughStyle = .single }
        if let link = style.link, let url = URL(string: link) {
            piece.link = url
            piece.foregroundColor = Brand.violet
            piece.underlineStyle = .single
        }
    }

    // MARK: Positions

    /// Where the caret is, as (line, offset into the line's words), which survives redrawing
    /// even when markers in front of it change length.
    struct Place: Equatable {
        var line: Int
        var offset: Int
    }

    static func place(of index: AttributedString.Index, in text: AttributedString, document: RichDocument) -> Place {
        let lines = lines(of: text)
        for (number, range) in lines.enumerated() where index <= range.upperBound {
            let raw = text.characters.distance(from: range.lowerBound, to: index)
            let total = text.characters.distance(from: range.lowerBound, to: range.upperBound)
            let words = number < document.blocks.count ? document.blocks[number].text.count : total
            let lead = max(0, total - words)
            return Place(line: number, offset: max(0, min(words, raw - lead)))
        }
        return Place(line: max(0, lines.count - 1), offset: 0)
    }

    static func index(of place: Place, in text: AttributedString, document: RichDocument) -> AttributedString.Index {
        let lines = lines(of: text)
        guard !lines.isEmpty else { return text.endIndex }
        let number = min(place.line, lines.count - 1)
        let range = lines[number]
        let total = text.characters.distance(from: range.lowerBound, to: range.upperBound)
        let words = number < document.blocks.count ? document.blocks[number].text.count : total
        let lead = max(0, total - words)
        let offset = min(lead + place.offset, total)
        return text.characters.index(range.lowerBound, offsetBy: offset)
    }
}

extension Color {
    /// `#rrggbb`, or nil.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
