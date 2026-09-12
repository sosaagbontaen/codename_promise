import Foundation
@testable import CodenamePromiseCore

/// Answers HTTP requests from a closure, so `APIClient` can be tested against a real
/// `URLSession` without a server.
///
/// The alternative is stubbing at the service protocol, which is what the rest of the suite
/// does and is right for testing coordinators. It is wrong here: the thing under test is how
/// `APIClient` turns status codes into `APIError`, so the status code has to be real.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Global, because `URLProtocol` is instantiated by `URLSession` and there is nowhere to
    /// hand per-instance state. That makes it shared mutable state between tests, so any
    /// suite using it must be `.serialized` — without that, tests overwrite each other's
    /// handler and every one of them sees whichever ran last.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Result<String, APIError>)?

    static func session(
        _ handler: @escaping @Sendable (URLRequest) -> Result<String, APIError>
    ) -> URLSession {
        Self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch handler(request) {
        case .success(let body):
            respond(status: 200, body: body, url: url)
        case .failure(.unauthorized):
            respond(status: 401, body: "{}", url: url)
        case .failure(.server(let status, _)):
            respond(status: status, body: "{}", url: url)
        case .failure:
            // Everything else is a transport failure as far as URLSession is concerned.
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    private func respond(status: Int, body: String, url: URL) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
