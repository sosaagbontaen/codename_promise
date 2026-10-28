import Foundation

/// An entry's writing as structured text: lines that are headings, lists, checkboxes or
/// quotes, made of runs that can be bold, coloured, linked and so on.
///
/// It exists so the editor can be rich while what's stored stays Markdown. `rawText` is
/// still a string anyone can read, export, sync to Notion or hand to Arrange; this is just
/// the shape the editor works in. Round-tripping is lossless for everything the editor can
/// produce, and plain text written before the editor existed reads in as itself.
///
/// The Markdown is line-based, one block per line, like the plain entries it replaces. What
/// Markdown has no syntax for uses small HTML that Notion and most readers understand:
///
/// - underline: `<u>text</u>`
/// - colour, highlight, size: `<span style="color:#e5534b;background-color:#fff3a0;font-size:1.25em">`
/// - toggle headings: `<details open><summary>## Heading</summary>` ... `</details>`;
///   `<details>` without `open` is a folded one
public struct RichDocument: Equatable, Sendable {
    public var blocks: [Block]

    public init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    public struct Block: Equatable, Hashable, Sendable {
        public var kind: Kind
        /// Nesting depth for lists and indented lines.
        public var indent: Int
        public var runs: [Run]
        /// For a folded toggle heading, the lines tucked away beneath it.
        public var folded: [Block]?

        public init(kind: Kind = .paragraph, indent: Int = 0, runs: [Run] = [], folded: [Block]? = nil) {
            self.kind = kind
            self.indent = indent
            self.runs = runs
            self.folded = folded
        }

        public var text: String { runs.map(\.text).joined() }
    }

    public enum Kind: Equatable, Hashable, Sendable {
        case paragraph
        /// 1 to 3. A toggle heading folds away everything under it, up to the next heading of
        /// the same or a higher level.
        case heading(level: Int, toggle: Bool)
        case bullet
        case numbered
        case check(done: Bool)
        case quote
    }

    public struct Run: Equatable, Hashable, Sendable {
        public var text: String
        public var style: Style

        public init(_ text: String, _ style: Style = Style()) {
            self.text = text
            self.style = style
        }
    }

    public struct Style: Equatable, Hashable, Sendable {
        public var bold = false
        public var italic = false
        public var underline = false
        public var strike = false
        public var link: String?
        /// `#rrggbb`.
        public var color: String?
        public var highlight: String?
        /// Relative to body text: 0.85 small, 1.25 large, 1.5 huge. Nil is normal.
        public var size: Double?

        public init(
            bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false,
            link: String? = nil, color: String? = nil, highlight: String? = nil, size: Double? = nil
        ) {
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.strike = strike
            self.link = link
            self.color = color
            self.highlight = highlight
            self.size = size
        }

        var hasSpan: Bool { color != nil || highlight != nil || size != nil }
    }
}

// MARK: - Plain text

extension RichDocument {
    /// The words, with list markers kept and every other bit of markup gone. What goes to
    /// Arrange and transcription merging, so a model never sees a tag and the word guard
    /// never mistakes one for a word.
    public var plainText: String {
        Self.flatten(blocks).map { block -> String in
            let pad = String(repeating: "  ", count: block.indent)
            switch block.kind {
            case .bullet: return pad + "- " + block.text
            case .numbered: return pad + "- " + block.text
            case .check(let done): return pad + (done ? "- [x] " : "- [ ] ") + block.text
            default: return pad + block.text
            }
        }
        .joined(separator: "\n")
    }

    /// Blocks with folded content brought back in line, for anything that reads every word.
    static func flatten(_ blocks: [Block]) -> [Block] {
        blocks.flatMap { block -> [Block] in
            var head = block
            let folded = head.folded ?? []
            head.folded = nil
            return [head] + flatten(folded)
        }
    }

    public static func plainText(ofMarkdown markdown: String) -> String {
        RichDocument(markdown: markdown).plainText
    }
}

// MARK: - Writing Markdown

extension RichDocument {
    public var markdown: String {
        var lines: [String] = []
        write(blocks, into: &lines)
        return lines.joined(separator: "\n")
    }

    private func write(_ blocks: [Block], into lines: inout [String]) {
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if case .heading(let level, true) = block.kind {
                // The toggle owns the lines after it up to the next heading at its level or
                // above; when folded they live in `folded` instead.
                var end = index + 1
                while end < blocks.count {
                    if case .heading(let other, _) = blocks[end].kind, other <= level { break }
                    end += 1
                }
                let open = block.folded == nil
                lines.append(open ? "<details open>" : "<details>")
                lines.append("<summary>" + String(repeating: "#", count: level) + " " + Self.inline(block.runs) + "</summary>")
                // Folded, everything it owns is in `folded`; what follows it is outside.
                write(open ? Array(blocks[(index + 1)..<end]) : (block.folded ?? []), into: &lines)
                lines.append("</details>")
                index = open ? end : index + 1
                continue
            }
            lines.append(Self.line(block))
            index += 1
        }
    }

    static func line(_ block: Block) -> String {
        let pad = String(repeating: "  ", count: block.indent)
        let body = inline(block.runs)
        switch block.kind {
        case .paragraph: return pad + escapeLineStart(body)
        case .heading(let level, _): return String(repeating: "#", count: level) + " " + body
        case .bullet: return pad + "- " + body
        case .numbered: return pad + "1. " + body
        case .check(let done): return pad + (done ? "- [x] " : "- [ ] ") + body
        case .quote: return pad + "> " + body
        }
    }

    /// A paragraph that happens to start like a list or heading is escaped, so it reads back
    /// as the paragraph it was.
    private static func escapeLineStart(_ text: String) -> String {
        // A leading space would read back as indentation.
        if let first = text.first, first == " " || first == "\t" { return "\\" + text }
        for marker in ["#", "- ", "* ", "> ", "+ "] where text.hasPrefix(marker) {
            return "\\" + text
        }
        // "2." and "2)" both read as a numbered item, so both are escaped.
        if let first = text.firstIndex(where: { $0 == "." || $0 == ")" }), text[..<first].allSatisfy(\.isNumber), first > text.startIndex,
           text[text.index(after: first)...].hasPrefix(" ") {
            return "\\" + text
        }
        return text
    }

    static func inline(_ runs: [Run]) -> String {
        merged(runs).map { run in
            var out = escape(run.text)
            let style = run.style
            // Markdown's own markers when they're unambiguous, which is almost always: a styled
            // word. Text that starts or ends with a space can't take them (Markdown won't open
            // or close emphasis against whitespace), so it gets the equivalent tag instead.
            let clean = run.text.first.map { !$0.isWhitespace } == true
                && run.text.last.map { !$0.isWhitespace } == true
            if clean {
                if style.bold && style.italic { out = "***" + out + "***" }
                else if style.bold { out = "**" + out + "**" }
                else if style.italic { out = "*" + out + "*" }
                if style.strike { out = "~~" + out + "~~" }
            } else {
                if style.italic { out = "<i>" + out + "</i>" }
                if style.bold { out = "<b>" + out + "</b>" }
                if style.strike { out = "<s>" + out + "</s>" }
            }
            if style.underline { out = "<u>" + out + "</u>" }
            if style.hasSpan {
                var css: [String] = []
                if let color = style.color { css.append("color:\(color)") }
                if let highlight = style.highlight { css.append("background-color:\(highlight)") }
                if let size = style.size { css.append("font-size:\(format(size))em") }
                out = "<span style=\"\(css.joined(separator: ";"))\">" + out + "</span>"
            }
            if let link = style.link { out = "[" + out + "](" + link + ")" }
            return out
        }
        .joined()
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    /// Neighbouring runs with the same style become one, so `**a****b**` never appears.
    static func merged(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.style == run.style {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    private static let escaped: Set<Character> = ["\\", "*", "_", "~", "[", "]", "<", ">", "`"]

    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if escaped.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

// MARK: - Reading Markdown

extension RichDocument {
    public init(markdown: String) {
        var blocks: [Block] = []
        var stack: [(heading: Int, open: Bool, start: Int)] = []
        for raw in markdown.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "<details open>" || trimmed == "<details>" {
                stack.append((heading: blocks.count, open: trimmed == "<details open>", start: blocks.count + 1))
                continue
            }
            if trimmed.hasPrefix("<summary>"), trimmed.hasSuffix("</summary>"), !stack.isEmpty {
                let inner = String(trimmed.dropFirst("<summary>".count).dropLast("</summary>".count))
                var heading = Self.parseLine(inner)
                if case .heading(let level, _) = heading.kind {
                    heading.kind = .heading(level: level, toggle: true)
                } else {
                    heading = Block(kind: .heading(level: 2, toggle: true), runs: heading.runs)
                }
                stack[stack.count - 1].heading = blocks.count
                stack[stack.count - 1].start = blocks.count + 1
                blocks.append(heading)
                continue
            }
            if trimmed == "</details>", let toggle = stack.popLast() {
                if !toggle.open, toggle.heading < blocks.count {
                    let content = Array(blocks[toggle.start...])
                    blocks.removeSubrange(toggle.start...)
                    blocks[toggle.heading].folded = content
                }
                continue
            }
            blocks.append(Self.parseLine(raw))
        }
        self.blocks = blocks
    }

    static func parseLine(_ raw: String) -> Block {
        let spaces = raw.prefix { $0 == " " || $0 == "\t" }
        let indent = spaces.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        var rest = String(raw.dropFirst(spaces.count))

        if rest.hasPrefix("\\") {
            return Block(kind: .paragraph, indent: indent, runs: parseInline(rest))
        }
        for level in (1...6).reversed() {
            let marker = String(repeating: "#", count: level) + " "
            if rest.hasPrefix(marker) {
                return Block(kind: .heading(level: min(level, 3), toggle: false), runs: parseInline(String(rest.dropFirst(marker.count))))
            }
        }
        for (marker, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false), ("* [x] ", true)]
        where rest.hasPrefix(marker) {
            return Block(kind: .check(done: done), indent: indent, runs: parseInline(String(rest.dropFirst(marker.count))))
        }
        for marker in ["- ", "* ", "+ ", "• "] where rest.hasPrefix(marker) {
            return Block(kind: .bullet, indent: indent, runs: parseInline(String(rest.dropFirst(marker.count))))
        }
        if let dot = rest.firstIndex(where: { $0 == "." || $0 == ")" }), dot > rest.startIndex,
           rest[..<dot].allSatisfy(\.isNumber), rest[rest.index(after: dot)...].hasPrefix(" ") {
            rest = String(rest[rest.index(dot, offsetBy: 2)...])
            return Block(kind: .numbered, indent: indent, runs: parseInline(rest))
        }
        if rest.hasPrefix("> ") || rest == ">" {
            return Block(kind: .quote, indent: indent, runs: parseInline(String(rest.dropFirst(min(2, rest.count)))))
        }
        return Block(kind: .paragraph, indent: indent, runs: parseInline(rest))
    }

    /// A small, forgiving inline parser: escapes, emphasis, strike, underline, spans and
    /// links. Anything it doesn't recognise stays as the characters it is.
    /// Characters that can start markup. A line with none of them is plain words, which is
    /// most of a journal, and skips the parser entirely: the list reads every entry's text on
    /// each reload, so this is the difference between instant and seconds.
    private static let markupStarts: Set<Character> = ["*", "_", "~", "<", "[", "\\"]

    static func parseInline(_ text: String) -> [Run] {
        if !text.contains(where: markupStarts.contains) {
            return text.isEmpty ? [] : [Run(text, Style())]
        }
        var parser = InlineParser(Array(text))
        return merged(parser.parse(Style()))
    }

    private struct InlineParser {
        let chars: [Character]
        var position = 0

        init(_ chars: [Character]) { self.chars = chars }

        func peek(_ token: String) -> Bool {
            matches(token, at: position)
        }

        /// Compared in place: building arrays for every token at every character made a long
        /// entry take milliseconds to read.
        func matches(_ token: String, at start: Int) -> Bool {
            var index = start
            for character in token {
                guard index < chars.count, chars[index] == character else { return false }
                index += 1
            }
            return true
        }

        /// Whether `token` closes later on this line, so an unmatched `*` stays a `*`. As in
        /// Markdown, a closer can't follow a space and an opener can't precede one.
        func closes(_ token: String, from start: Int) -> Bool {
            let isTag = token.hasPrefix("<")
            guard start < chars.count, isTag || !chars[start].isWhitespace else { return false }
            let length = token.count
            var index = start
            while index + length <= chars.count {
                if chars[index] == "\\" { index += 2; continue }
                if matches(token, at: index), index > start,
                   isTag || !chars[index - 1].isWhitespace {
                    return true
                }
                index += 1
            }
            return false
        }

        mutating func parse(_ style: Style, until terminator: String? = nil) -> [Run] {
            var runs: [Run] = []
            var buffer = ""
            func flush() {
                if !buffer.isEmpty { runs.append(Run(buffer, style)); buffer = "" }
            }
            while position < chars.count {
                if let terminator, peek(terminator) {
                    position += terminator.count
                    flush()
                    return runs
                }
                let c = chars[position]
                if c == "\\", position + 1 < chars.count {
                    buffer.append(chars[position + 1])
                    position += 2
                    continue
                }
                if let (open, close, apply) = opener(), closes(close, from: position + open.count) {
                    flush()
                    position += open.count
                    var inner = style
                    apply(&inner)
                    runs += parse(inner, until: close)
                    continue
                }
                if c == "<", peek("<span style=\""), let end = spanStyleEnd() {
                    let css = String(chars[(position + 13)..<end])
                    var inner = style
                    Self.apply(css: css, to: &inner)
                    flush()
                    position = end + 2
                    runs += parse(inner, until: "</span>")
                    continue
                }
                if c == "[", let (label, url, after) = link() {
                    flush()
                    var inner = style
                    inner.link = url
                    var sub = InlineParser(Array(label))
                    runs += sub.parse(inner)
                    position = after
                    continue
                }
                buffer.append(c)
                position += 1
            }
            flush()
            return runs
        }

        func opener() -> (String, String, (inout Style) -> Void)? {
            switch chars[position] {
            case "*", "~", "<", "_": break
            default: return nil
            }
            if peek("***") { return ("***", "***", { $0.bold = true; $0.italic = true }) }
            if peek("**") { return ("**", "**", { $0.bold = true }) }
            if peek("~~") { return ("~~", "~~", { $0.strike = true }) }
            if peek("<u>") { return ("<u>", "</u>", { $0.underline = true }) }
            if peek("<b>") { return ("<b>", "</b>", { $0.bold = true }) }
            if peek("<i>") { return ("<i>", "</i>", { $0.italic = true }) }
            if peek("<s>") { return ("<s>", "</s>", { $0.strike = true }) }
            if peek("*") { return ("*", "*", { $0.italic = true }) }
            if peek("_"), position == 0 || chars[position - 1] == " " { return ("_", "_", { $0.italic = true }) }
            return nil
        }

        func spanStyleEnd() -> Int? {
            var index = position + 13
            while index + 1 < chars.count {
                if chars[index] == "\"" && chars[index + 1] == ">" { return index }
                index += 1
            }
            return nil
        }

        /// `[label](url)`, with the closing bracket matched past escapes and nesting.
        func link() -> (String, String, Int)? {
            var depth = 0
            var index = position
            while index < chars.count {
                let c = chars[index]
                if c == "\\" { index += 2; continue }
                if c == "[" { depth += 1 }
                if c == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index += 1
            }
            guard index + 1 < chars.count, chars[index] == "]", chars[index + 1] == "(" else { return nil }
            guard let close = chars[(index + 2)...].firstIndex(of: ")") else { return nil }
            let label = String(chars[(position + 1)..<index])
            let url = String(chars[(index + 2)..<close])
            return (label, url, close + 1)
        }

        static func apply(css: String, to style: inout Style) {
            for declaration in css.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0].lowercased() {
                case "color": style.color = parts[1]
                case "background-color", "background": style.highlight = parts[1]
                case "font-size":
                    style.size = Double(parts[1].replacingOccurrences(of: "em", with: ""))
                default: break
                }
            }
        }
    }
}
