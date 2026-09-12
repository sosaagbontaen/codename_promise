import Foundation
import Testing
@testable import CodenamePromiseCore

/// Telling a wrong address from a wrong key.
///
/// Before this existed the app could only say "it doesn't work", so both failures looked
/// identical and the way to find out which was to record something and watch it fail. Each
/// case here is a distinct thing that can be true, and each has a different fix.
// Serialized: StubURLProtocol keeps its handler in global state. See its comment.
@Suite("Backend check", .serialized)
struct BackendCheckTests {

    /// Answers the two endpoints from a script, so every branch can be exercised without a
    /// server, a key or a network.
    private func checker(
        health: Result<String, APIError>,
        auth: Result<String, APIError> = .success("{\"ok\":true}"),
        hasKey: Bool = true,
        configured: Bool = true
    ) -> BackendChecker {
        let session = StubURLProtocol.session { request in
            let path = request.url?.path ?? ""
            return path.contains("auth/check") ? auth : health
        }
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: configured ? URL(string: "https://example.com") : nil,
                apiKey: { hasKey ? "k" : nil }
            ),
            session: session
        )
        return BackendChecker(client: client, hasStoredKey: { hasKey })
    }

    private let ok = "{\"auth_required\":true,\"transcription\":\"groq\",\"formatting\":\"groq\"}"

    @Test("no address is not a failure")
    func noAddress() async {
        let result = await checker(health: .success(ok), configured: false).check()
        #expect(result == .noAddress)
        #expect(result.message.contains("saved on this device"))
    }

    @Test("a dead address says so, and does not blame the key")
    func unreachable() async {
        let result = await checker(health: .failure(.transport("boom"))).check()
        guard case .unreachable = result else {
            Issue.record("expected unreachable, got \(result)")
            return
        }
        #expect(!result.message.lowercased().contains("key"))
    }

    /// The distinction the whole thing exists for.
    @Test("a good address and a bad key blames the key, not the address")
    func keyRejected() async {
        let result = await checker(health: .success(ok), auth: .failure(.unauthorized)).check()
        #expect(result == .keyRejected)
        #expect(result.message.contains("key was rejected"))
        #expect(result.message.contains("address works"))
    }

    @Test("a server that wants a key you do not have says exactly that")
    func keyMissing() async {
        let result = await checker(health: .success(ok), hasKey: false).check()
        #expect(result == .keyMissing)
    }

    @Test("a working server reports what it can do")
    func ready() async {
        let result = await checker(health: .success(ok)).check()
        #expect(result == .ready(transcription: "groq", formatting: "groq"))
        #expect(result.isWorking)
        #expect(result.hasRealProviders)
    }

    /// "Connected" alone would be misleading against a stub server, which answers everything
    /// happily and transcribes nothing useful.
    @Test("a stub server is reported as connected but not working")
    func stubs() async {
        let stubbed = "{\"auth_required\":false,\"transcription\":\"stub\",\"formatting\":\"stub\"}"
        let result = await checker(health: .success(stubbed)).check()
        #expect(result.isWorking)
        #expect(result.hasRealProviders == false)
        #expect(result.message.contains("no AI provider"))
    }

    /// A backend deployed before /auth/check existed. The address and key are as proven as
    /// they can be, so inventing a failure the user cannot act on would be wrong.
    @Test("an older server without the check still reports ready")
    func olderServer() async {
        let result = await checker(
            health: .success(ok), auth: .failure(.server(status: 404, message: nil))
        ).check()
        #expect(result == .ready(transcription: "groq", formatting: "groq"))
    }
}

/// What the user is shown when the server says no.
///
/// The whole body used to be handed to the UI, so somebody trying to use their journal was
/// shown `{"detail":"Pick a Notion database first."}` — braces, quotes and all.
@Suite("Server error messages")
struct ServerMessageTests {

    private func message(_ body: String) -> String? {
        APIClient.readableMessage(from: Data(body.utf8))
    }

    @Test("a FastAPI detail is unwrapped")
    func unwrapsDetail() {
        #expect(message(#"{"detail":"Pick a Notion database first."}"#)
                == "Pick a Notion database first.")
    }

    @Test("other common shapes are unwrapped too")
    func unwrapsOthers() {
        #expect(message(#"{"message":"Too many requests."}"#) == "Too many requests.")
        #expect(message(#"{"error":"Bad model."}"#) == "Bad model.")
    }

    /// An unrecognised body is still better than no message, so it is passed through.
    @Test("an unfamiliar body is passed through rather than swallowed")
    func passesThroughUnknown() {
        #expect(message("Service Unavailable") == "Service Unavailable")
    }

    @Test("an empty body produces no message rather than an empty one")
    func emptyIsNil() {
        #expect(message("") == nil)
        #expect(message("   ") == nil)
    }

    /// A detail that is not a string, which FastAPI does for validation errors, must not be
    /// rendered as a Swift array description.
    @Test("a non-string detail falls back to the raw body")
    func nonStringDetail() {
        let body = #"{"detail":[{"loc":["body","x"],"msg":"field required"}]}"#
        #expect(message(body) == body)
    }
}
