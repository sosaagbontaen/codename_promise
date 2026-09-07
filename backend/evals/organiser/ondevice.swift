import Foundation
import FoundationModels

@Generable
struct Section {
    @Guide(description: "A short heading in the writer's own voice")
    var heading: String
    @Guide(description: "The section written in the writer's own words, flowing prose")
    var body: String
    @Guide(description: "Every input line number this section is built from")
    var sources: [Int]
}

@Generable
struct Entry {
    @Guide(description: "A short title taken from what they actually said")
    var title: String
    var sections: [Section]
    @Guide(description: "Line numbers that were pure filler and carry no content")
    var dropped: [Int]
}

let instructions = """
You are organising a spoken journal entry. The input is a transcript of someone talking \
freely about their day, numbered one sentence per line. People ramble: they jump between \
topics and return to something they mentioned earlier.

Group related thoughts together, including ones far apart in the transcript. Use their own \
words and voice. You may drop pure filler such as "um" or "where was I". Never invent a fact \
or a feeling they did not say. Never soften an uncomfortable thought.

Every input line number must appear exactly once, either in a section's sources or in dropped.
"""

let model = SystemLanguageModel.default
switch model.availability {
case .available:
    print("  model: AVAILABLE on this machine")
case .unavailable(let reason):
    print("  model: UNAVAILABLE — \(reason)")
    exit(1)
@unknown default:
    print("  model: unknown state"); exit(1)
}

let raw = try String(contentsOfFile: "ramble.txt", encoding: .utf8)
    .replacingOccurrences(of: "\n", with: " ")
var sentences: [String] = []
raw.enumerateSubstrings(in: raw.startIndex..., options: .bySentences) { s, _, _, _ in
    if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
}
let numbered = sentences.enumerated().map { "\($0.offset + 1). \($0.element)" }
    .joined(separator: "\n")
print("  input: \(sentences.count) sentences, \(raw.split(separator: " ").count) words")

let clock = Date()
let session = LanguageModelSession(instructions: instructions)
do {
    let reply = try await session.respond(to: numbered, generating: Entry.self)
    let e = reply.content
    let secs = Date().timeIntervalSince(clock)
    print("  time:  \(String(format: "%.1f", secs))s  (fully on device, no network)\n")
    print("TITLE: \(e.title)\n")
    for s in e.sections {
        print("## \(s.heading)  [\(s.sources.count) lines]")
        print("\(s.body)\n")
    }
    var cited = Set<Int>()
    for s in e.sections { cited.formUnion(s.sources) }
    let all = Set(1...sentences.count)
    let uncited = all.subtracting(cited).subtracting(Set(e.dropped)).sorted()
    print(String(repeating: "=", count: 66))
    print("GUARD")
    print("  coverage         \(cited.count)/\(sentences.count) cited")
    print("  uncited (silent) \(uncited.isEmpty ? "none" : "\(uncited)")")
    print("  dropped          \(e.dropped.sorted())")
} catch {
    print("  FAILED: \(error)")
}
