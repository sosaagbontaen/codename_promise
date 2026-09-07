import Foundation
import FoundationModels

let raw = try String(contentsOfFile: "ramble.txt", encoding: .utf8)
    .replacingOccurrences(of: "\n", with: " ")
let instructions = "Organise this spoken journal entry into sections, using the writer's own words."

print("  full 589-word journal entry, 4 attempts, fresh session each time:")
for i in 1...4 {
    let session = LanguageModelSession(instructions: instructions)
    do {
        let r = try await session.respond(to: raw)
        print("    \(i)  PASS      (\(r.content.split(separator: " ").count) words out)")
    } catch let e as LanguageModelSession.GenerationError {
        switch e {
        case .refusal:                 print("    \(i)  REFUSED   sensitive content")
        case .exceededContextWindowSize: print("    \(i)  TOO LONG  context window")
        default:                       print("    \(i)  ERROR     \(e)")
        }
    } catch { print("    \(i)  ERROR     \(error)") }
}

// How much journal actually fits in 4,096 tokens?
print("\n  how long a recording fits the 4,096-token window:")
for mins in [4, 8, 12] {
    let words = mins * 140                     // ~140 wpm conversational speech
    let text = String(repeating: "I talked about my day and what happened at work. ", count: words / 10)
    let session = LanguageModelSession(instructions: instructions)
    do { _ = try await session.respond(to: text); print("    ~\(mins) min (\(words) words)  fits") }
    catch let e as LanguageModelSession.GenerationError {
        if case .exceededContextWindowSize = e { print("    ~\(mins) min (\(words) words)  EXCEEDS WINDOW") }
        else { print("    ~\(mins) min (\(words) words)  \(e)") }
    } catch { print("    ~\(mins) min  \(error)") }
}
