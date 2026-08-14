import Foundation

/// What the app is allowed to know about the Notion connection.
///
/// Deliberately no access token. The backend holds it and never sends it here, so it can't
/// end up in a device backup, a crash report, or anything the app logs. See ADR-022.
public struct NotionConnectionStatus: Sendable, Hashable, Codable {
    /// Signed in to a Notion workspace.
    public let connected: Bool
    /// Signed in *and* pointed at a database. Both are needed before sync can work, and they
    /// are separate states because "authorised but hasn't picked a database yet" is a real
    /// and common place for a user to be.
    public let ready: Bool
    /// Whether the server has Notion integration credentials at all. False means there is
    /// nothing for the user to do — the problem is server configuration, not their account.
    public let configurable: Bool
    public let workspaceName: String?
    public let databaseId: String?
    public let databaseTitle: String?
    /// Identifies which Notion workspace and database this is. Cached page, file and block
    /// IDs are only meaningful against the destination that issued them.
    public let destinationFingerprint: String?

    public init(
        connected: Bool,
        ready: Bool,
        configurable: Bool,
        workspaceName: String? = nil,
        databaseId: String? = nil,
        databaseTitle: String? = nil,
        destinationFingerprint: String? = nil
    ) {
        self.connected = connected
        self.ready = ready
        self.configurable = configurable
        self.workspaceName = workspaceName
        self.databaseId = databaseId
        self.databaseTitle = databaseTitle
        self.destinationFingerprint = destinationFingerprint
    }

    public static let disconnected = NotionConnectionStatus(
        connected: false, ready: false, configurable: false
    )

    private enum CodingKeys: String, CodingKey {
        case connected, ready, configurable
        case workspaceName = "workspace_name"
        case databaseId = "database_id"
        case databaseTitle = "database_title"
        case destinationFingerprint = "destination_fingerprint"
    }
}

public struct NotionDatabase: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// An existing entry in the destination, as shown in the "add to an existing entry" picker.
///
/// Carries only what identifies a page. Its content is deliberately absent: appending never
/// reads the page, which is precisely what stops it flattening blocks the app can't model.
public struct NotionPage: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let entryDate: String?
    public let lastEditedTime: String?

    public init(id: String, title: String, entryDate: String? = nil, lastEditedTime: String? = nil) {
        self.id = id
        self.title = title
        self.entryDate = entryDate
        self.lastEditedTime = lastEditedTime
    }

    private enum CodingKeys: String, CodingKey {
        case id, title
        case entryDate = "entry_date"
        case lastEditedTime = "last_edited_time"
    }
}

public protocol NotionConnectionService: Sendable {
    /// The URL to open in a web authentication session. Not fetched by the app — handing it
    /// to the system browser is the point, so the user types their Notion password into
    /// Notion's page and never into ours.
    var authorizationURL: URL? { get }

    func status() async throws -> NotionConnectionStatus
    func databases() async throws -> [NotionDatabase]
    func pages() async throws -> [NotionPage]
    func selectDatabase(id: String) async throws -> NotionConnectionStatus
    func disconnect() async throws
}

// MARK: - HTTP

public struct HTTPNotionConnectionService: NotionConnectionService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public var authorizationURL: URL? {
        client.baseURL?.appendingPathComponent("notion/oauth/start")
    }

    public func status() async throws -> NotionConnectionStatus {
        try await client.get(path: "notion/connection", expecting: NotionConnectionStatus.self)
    }

    private struct DatabaseList: Decodable {
        let databases: [NotionDatabase]
    }

    public func databases() async throws -> [NotionDatabase] {
        try await client.get(path: "notion/databases", expecting: DatabaseList.self).databases
    }

    private struct PageList: Decodable {
        let pages: [NotionPage]
    }

    public func pages() async throws -> [NotionPage] {
        try await client.get(path: "notion/pages", expecting: PageList.self).pages
    }

    private struct SelectBody: Encodable, Sendable {
        let database_id: String
    }

    public func selectDatabase(id: String) async throws -> NotionConnectionStatus {
        try await client.postJSON(
            path: "notion/database",
            body: SelectBody(database_id: id),
            expecting: NotionConnectionStatus.self
        )
    }

    private struct Ignored: Decodable {}

    public func disconnect() async throws {
        _ = try await client.delete(path: "notion/connection", expecting: Ignored.self)
    }
}
