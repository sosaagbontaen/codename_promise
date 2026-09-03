import Foundation

// MARK: - Configuration

/// Where the backend lives and how to authenticate to it.
///
/// `baseURL` is optional on purpose. An unconfigured backend is not an error state — the app
/// must behave exactly as it does offline: capture and editing work, everything else queues
/// visibly. See ADR-019a.
public struct APIConfiguration: Sendable {
    public let baseURL: URL?
    /// Read lazily so the key is fetched from the Keychain at call time, never held in a
    /// long-lived value that could end up in a log or a crash report. See ADR-022.
    public let apiKey: @Sendable () -> String?

    public init(baseURL: URL?, apiKey: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public var isConfigured: Bool { baseURL != nil }
}

// MARK: - Errors

public enum APIError: Error, Sendable, Equatable {
    /// No backend configured. Treated as "offline", never as a failure to show the user.
    case notConfigured
    case offline
    case transport(String)
    case server(status: Int, message: String?)
    case decoding(String)
    case unauthorized

    /// Whether retrying could plausibly succeed.
    ///
    /// This distinction is what keeps the queue from hammering a request that will never
    /// work: a 400 means the payload is wrong and retrying is pointless, while a 503 or a
    /// dropped connection deserves another go later.
    public var isRetryable: Bool {
        switch self {
        case .notConfigured, .offline, .transport:
            true
        case .server(let status, _):
            status == 408 || status == 429 || (500...599).contains(status)
        case .decoding:
            false
        case .unauthorized:
            false
        }
    }

    /// Phrasing for the user. Never implies anything was lost, because nothing ever is.
    public var userFacingMessage: String {
        switch self {
        case .notConfigured:
            "No backend configured yet. Saved on this device."
        case .offline:
            "Offline. Saved on this device, and it will sync when you're back."
        case .transport:
            "Couldn't reach the server. Saved on this device."
        case .server(let status, _) where status == 429:
            "Server is busy. Will try again shortly."
        case .server:
            "The server had a problem. Saved on this device."
        case .decoding:
            "The server sent something unexpected. Saved on this device."
        case .unauthorized:
            "Couldn't authenticate. Check the API key in Settings."
        }
    }
}

// MARK: - Client

/// Thin `URLSession` wrapper: builds requests, applies auth and idempotency, maps failures
/// onto `APIError`. Deliberately knows nothing about drafts.
public struct APIClient: Sendable {
    private let configuration: APIConfiguration
    private let session: URLSession
    private let reachability: any NetworkReachability

    public init(
        configuration: APIConfiguration,
        session: URLSession = .shared,
        reachability: any NetworkReachability = AlwaysReachable()
    ) {
        self.configuration = configuration
        self.session = session
        self.reachability = reachability
    }

    /// The configured backend, if there is one. Used to build the URL handed to a web
    /// authentication session, which the app opens itself rather than fetching.
    public var baseURL: URL? { configuration.baseURL }

    public var isConfigured: Bool { configuration.isConfigured }

    // MARK: Verbs

    public func get<Response: Decodable>(
        path: String,
        query: [String: String] = [:],
        expecting: Response.Type
    ) async throws -> Response {
        let request = try makeRequest(
            path: path, method: "GET", idempotencyKey: nil, query: query
        )
        return try decode(Response.self, from: try await perform(request))
    }

    public func delete<Response: Decodable>(
        path: String,
        expecting: Response.Type
    ) async throws -> Response {
        let request = try makeRequest(path: path, method: "DELETE", idempotencyKey: nil)
        return try decode(Response.self, from: try await perform(request))
    }

    // MARK: JSON

    public func postJSON<Request: Encodable & Sendable, Response: Decodable>(
        path: String,
        body: Request,
        idempotencyKey: IdempotencyKey? = nil,
        expecting: Response.Type
    ) async throws -> Response {
        var request = try makeRequest(path: path, method: "POST", idempotencyKey: idempotencyKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw APIError.decoding("Couldn't encode the request: \(error.localizedDescription)")
        }
        let data = try await perform(request)
        return try decode(Response.self, from: data)
    }

    /// Multipart upload for a file already on disk.
    ///
    /// Note the file is read into memory to build the body. Fine for a dictation chunk;
    /// revisit with a streamed body or a background session before large video ships
    /// (ADR-009b).
    public func upload<Response: Decodable>(
        path: String,
        fileURL: URL,
        fieldName: String,
        fileName: String,
        mimeType: String,
        fields: [String: String] = [:],
        idempotencyKey: IdempotencyKey? = nil,
        expecting: Response.Type
    ) async throws -> Response {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            // The local file is missing or unreadable — a permanent failure for this item,
            // not a transport problem, so it must not be retried forever.
            throw APIError.decoding("Couldn't read \(fileURL.lastPathComponent).")
        }

        var request = try makeRequest(path: path, method: "POST", idempotencyKey: idempotencyKey)
        let boundary = "cp.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        let data = try await perform(request)
        return try decode(Response.self, from: data)
    }

    // MARK: - Internals

    private func makeRequest(
        path: String,
        method: String,
        idempotencyKey: IdempotencyKey?,
        query: [String: String] = [:]
    ) throws -> URLRequest {
        guard let baseURL = configuration.baseURL else { throw APIError.notConfigured }
        guard reachability.isReachable else { throw APIError.offline }

        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty {
            // Built through URLComponents rather than string interpolation: appending a
            // path component would percent-encode the "?" and quietly request a path that
            // does not exist.
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            if let built = components?.url { url = built }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60

        if let key = configuration.apiKey() {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            // Every mutating call carries this so a lost response can be replayed rather
            // than re-applied. See ADR-003.
            request.setValue(idempotencyKey.rawValue, forHTTPHeaderField: "Idempotency-Key")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw APIError.offline
            default:
                throw APIError.transport(error.localizedDescription)
            }
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("The response wasn't HTTP.")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw APIError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            throw APIError.server(status: http.statusCode, message: message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Backoff

public enum RetryPolicy {
    /// Exponential backoff with a ceiling, so a persistently failing item slows down instead
    /// of burning battery. Jitter-free because ordering here is single-consumer.
    public static func delay(forAttempt attempt: Int) -> Duration {
        let capped = min(max(attempt, 1), 8)
        let seconds = min(pow(2.0, Double(capped - 1)), 300)
        return .seconds(seconds)
    }

    public static func nextRetryDate(forAttempt attempt: Int, from now: Date = Date()) -> Date {
        let seconds = min(pow(2.0, Double(min(max(attempt, 1), 8) - 1)), 300)
        return now.addingTimeInterval(seconds)
    }
}
