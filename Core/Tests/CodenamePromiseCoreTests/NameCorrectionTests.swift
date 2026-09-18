import Foundation
import Testing

@testable import CodenamePromiseCore

/// Fixing the spelling of a name the transcriber always gets wrong.
///
/// The risk in a feature like this is not that it fails to fire. It is that it fires
/// somewhere nobody asked it to, in a journal, silently. Most of what is below is about that.
@Suite("Correcting names in a transcript")
struct NameCorrectionTests {

    private func corrections(_ pairs: [(String, String)]) -> NameCorrections {
        NameCorrections(pairs.map { NameCorrection(heard: $0.0, meant: $0.1) })
    }

    @Test("the name it always gets wrong comes out right")
    func theWholePoint() {
        let fixes = corrections([("Lizzie", "Lizzy"), ("Aiden", "Aidan")])
        #expect(fixes.apply(to: "Lizzie called, and Aiden is coming Tuesday.")
                == "Lizzy called, and Aidan is coming Tuesday.")
    }

    @Test("however the transcriber capitalised it")
    func caseInsensitiveMatching() {
        let fixes = corrections([("Lizzie", "Lizzy")])
        #expect(fixes.apply(to: "lizzie and LIZZIE and Lizzie") == "Lizzy and Lizzy and Lizzy")
    }

    /// The one that keeps this safe to run over somebody's journal.
    @Test("a name inside a longer word is left alone")
    func wholeWordsOnly() {
        let fixes = corrections([("Aiden", "Aidan")])
        #expect(fixes.apply(to: "We drove through Aidenfield to meet Aiden.")
                == "We drove through Aidenfield to meet Aidan.")
    }

    @Test("possessives and punctuation still match")
    func boundariesThatShouldMatch() {
        let fixes = corrections([("Lizzie", "Lizzy")])
        #expect(fixes.apply(to: "Lizzie's car. (Lizzie.) \"Lizzie\"!")
                == "Lizzy's car. (Lizzy.) \"Lizzy\"!")
    }

    @Test("a name of several words works")
    func multiWordNames() {
        let fixes = corrections([("Sam Oh", "Sam Osa")])
        #expect(fixes.apply(to: "Sam Oh rang.") == "Sam Osa rang.")
    }

    @Test("a transcript with nothing to fix comes back untouched")
    func leavesEverythingElseAlone() {
        let fixes = corrections([("Lizzie", "Lizzy")])
        let text = "Nothing in this sentence needs changing at all."
        #expect(fixes.apply(to: text) == text)
        #expect(NameCorrections().apply(to: text) == text)
    }

    /// Regex metacharacters in a name must be matched as themselves, not as syntax.
    @Test("a name with punctuation in it is not read as a pattern")
    func specialCharactersAreLiteral() {
        let fixes = corrections([("O'Neil", "O'Neill"), ("J.R.", "JR")])
        #expect(fixes.apply(to: "O'Neil and J.R. arrived.") == "O'Neill and JR arrived.")
        // And a name that looks like a wildcard matches nothing but itself.
        let wild = corrections([("A.C", "AC")])
        #expect(wild.apply(to: "ABC and A.C") == "ABC and AC")
    }

    /// `$1` in a replacement would otherwise be read as a capture group and vanish.
    @Test("a replacement containing regex syntax is inserted as written")
    func replacementIsLiteral() {
        let fixes = corrections([("Dollar", "$1 Bill")])
        #expect(fixes.apply(to: "Dollar came round.") == "$1 Bill came round.")
    }

    @Test("a correction that would do nothing is not stored")
    func uselessCorrectionsRejected() {
        #expect(NameCorrection(heard: "  ", meant: "Lizzy").isUsable == false)
        #expect(NameCorrection(heard: "Lizzy", meant: "").isUsable == false)
        // Same word either way: nothing to do, and storing it would let somebody think
        // they had fixed something.
        #expect(NameCorrection(heard: "Lizzy", meant: "lizzy").isUsable == false)
        #expect(NameCorrections([NameCorrection(heard: "", meant: "")]).isEmpty)
    }

    @Test("correcting the same heard spelling twice replaces the rule")
    func oneRulePerHeardSpelling() {
        var fixes = NameCorrections()
        fixes.add(NameCorrection(heard: "Lizzie", meant: "Lizzy"))
        fixes.add(NameCorrection(heard: "lizzie", meant: "Elizabeth"))
        #expect(fixes.count == 1, "a second rule for the same word could never fire")
        #expect(fixes.apply(to: "Lizzie") == "Elizabeth")
    }

    @Test("it says how many it would change before it changes them")
    func countsBeforeActing() {
        let fixes = corrections([("Lizzie", "Lizzy"), ("Aiden", "Aidan")])
        #expect(fixes.matchCount(in: "Lizzie, Aiden, lizzie, Aidenfield") == 3)
        #expect(fixes.matchCount(in: "Nothing here.") == 0)
    }

    @Test("removing a correction stops it firing")
    func removal() {
        var fixes = NameCorrections()
        fixes.add(NameCorrection(heard: "Lizzie", meant: "Lizzy"))
        fixes.remove("lizzie")
        #expect(fixes.isEmpty)
        #expect(fixes.apply(to: "Lizzie") == "Lizzie")
    }

    /// Applying one rule must not hand its output to the next as fresh input.
    @Test("a chain of corrections does not cascade into a name nobody typed")
    func noCascade() {
        let fixes = corrections([("Ann", "Anna"), ("Anna", "Annabel")])
        // Each rule sees the original text. Run in sequence instead, "Ann" would become
        // "Anna" and then "Annabel" — produced by two rules that were each right on their own.
        #expect(fixes.apply(to: "Ann") == "Anna")
        #expect(fixes.apply(to: "Anna") == "Annabel")
    }

    /// With rules for both a first name and a full name, the full name has to win.
    @Test("the longer name is matched first")
    func longestMatchWins() {
        let fixes = corrections([("Sam", "Samuel"), ("Sam Oh", "Sam Osa")])
        #expect(fixes.apply(to: "Sam Oh called Sam.") == "Sam Osa called Samuel.")
    }

    @Test("it survives being saved and loaded")
    func codable() throws {
        let fixes = corrections([("Lizzie", "Lizzy"), ("Aiden", "Aidan")])
        let data = try JSONEncoder().encode(fixes)
        let back = try JSONDecoder().decode(NameCorrections.self, from: data)
        #expect(back == fixes)
    }
}
