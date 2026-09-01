import Foundation
import Testing
@testable import CodenamePromiseCore

@MainActor
final class StubConnectionService: NotionConnectionService, @unchecked Sendable {
    var currentStatus: NotionConnectionStatus = .disconnected
    var availableDatabases: [NotionDatabase] = []
    var statusError: APIError?
    var selectError: APIError?
    private(set) var disconnectCount = 0
    private(set) var selectedIds: [String] = []

    nonisolated var authorizationURL: URL? { URL(string: "https://example.test/notion/oauth/start") }

    func status() async throws -> NotionConnectionStatus {
        if let statusError { throw statusError }
        return currentStatus
    }

    func databases() async throws -> [NotionDatabase] {
        if let statusError { throw statusError }
        return availableDatabases
    }

    var availablePages: [NotionPage] = []

    func pages() async throws -> [NotionPage] {
        if let statusError { throw statusError }
        return availablePages
    }

    var destinationDays: Set<CalendarDay> = []
    var entryDaysError: Error?

    func entryDays(from: CalendarDay, through: CalendarDay) async throws -> Set<CalendarDay> {
        if let entryDaysError { throw entryDaysError }
        return destinationDays.filter { $0 >= from && $0 <= through }
    }

    var destinationEntries: [DestinationEntryRow] = []
    var entryCoverageError: Error?

    func entryCoverage(
        from: CalendarDay, through: CalendarDay
    ) async throws -> [DestinationEntryRow] {
        if let entryCoverageError { throw entryCoverageError }
        return destinationEntries.filter { $0.day >= from && $0.day <= through }
    }

    func selectDatabase(id: String) async throws -> NotionConnectionStatus {
        selectedIds.append(id)
        if let selectError { throw selectError }
        currentStatus = NotionConnectionStatus(
            connected: true,
            ready: true,
            configurable: true,
            workspaceName: currentStatus.workspaceName,
            databaseId: id,
            databaseTitle: availableDatabases.first { $0.id == id }?.title
        )
        return currentStatus
    }

    func disconnect() async throws {
        disconnectCount += 1
        currentStatus = .disconnected
    }
}

@Suite("Notion connection")
@MainActor
struct ConnectionCoordinatorTests {

    private func makeConnected() -> StubConnectionService {
        let service = StubConnectionService()
        service.currentStatus = NotionConnectionStatus(
            connected: true, ready: false, configurable: true, workspaceName: "My Workspace"
        )
        service.availableDatabases = [
            NotionDatabase(id: "db-1", title: "Journal"),
            NotionDatabase(id: "db-2", title: "Scratch"),
        ]
        return service
    }

    @Test("a connected workspace lists its databases for the picker")
    func refreshLoadsDatabases() async {
        let sut = ConnectionCoordinator(service: makeConnected())
        await sut.refresh()

        #expect(sut.status.connected)
        #expect(sut.status.ready == false, "connected is not the same as ready")
        #expect(sut.databases.count == 2)
        #expect(sut.phase == .idle)
    }

    @Test("a disconnected workspace lists nothing")
    func disconnectedListsNothing() async {
        let service = StubConnectionService()
        let sut = ConnectionCoordinator(service: service)
        await sut.refresh()

        #expect(sut.databases.isEmpty)
        #expect(sut.status.connected == false)
    }

    @Test("choosing a database makes the connection ready")
    func selectingMakesReady() async {
        let service = makeConnected()
        let sut = ConnectionCoordinator(service: service)
        await sut.refresh()

        await sut.selectDatabase(NotionDatabase(id: "db-1", title: "Journal"))

        #expect(sut.status.ready)
        #expect(sut.status.databaseTitle == "Journal")
        #expect(service.selectedIds == ["db-1"])
        #expect(sut.selectingDatabaseId == nil, "the row spinner must clear")
    }

    /// The server rejects a database with no date column. That message is far more useful
    /// than anything the client could invent, so it has to survive to the screen.
    @Test("an unusable database surfaces the server's own explanation")
    func unusableDatabaseExplains() async {
        let service = makeConnected()
        service.selectError = .server(
            status: 422,
            message: #"{"detail":"That database has no date column."}"#
        )
        let sut = ConnectionCoordinator(service: service)
        await sut.refresh()

        await sut.selectDatabase(NotionDatabase(id: "db-2", title: "Scratch"))

        #expect(sut.phase == .failed("That database has no date column."))
        #expect(sut.status.ready == false)
    }

    @Test("cancelling sign-in is not an error")
    func cancellingIsNotFailure() async {
        let sut = ConnectionCoordinator(service: makeConnected())
        sut.beginAuthorizing()
        #expect(sut.phase == .authorizing)

        await sut.finishAuthorizing(cancelled: true)

        #expect(sut.phase == .idle)
    }

    @Test("completing sign-in re-reads server state rather than trusting the browser")
    func completingRefreshes() async {
        let service = makeConnected()
        let sut = ConnectionCoordinator(service: service)
        sut.beginAuthorizing()

        await sut.finishAuthorizing(cancelled: false)

        #expect(sut.status.connected)
        #expect(sut.databases.count == 2)
    }

    @Test("a server with no Notion credentials is reported as unavailable, not broken")
    func unconfiguredServerIsUnavailable() async {
        let service = StubConnectionService()
        service.currentStatus = NotionConnectionStatus(
            connected: false, ready: false, configurable: false
        )
        let sut = ConnectionCoordinator(service: service)
        await sut.refresh()

        #expect(sut.isUnavailable, "there is nothing for the user to do here")
        #expect(sut.phase == .idle, "and it is not an error state")
    }

    @Test("no backend configured is reported in the user's language")
    func noBackendIsReadable() async {
        let service = StubConnectionService()
        service.statusError = .notConfigured
        let sut = ConnectionCoordinator(service: service)
        await sut.refresh()

        #expect(sut.phase == .failed(APIError.notConfigured.userFacingMessage))
    }

    @Test("disconnecting clears local connection state")
    func disconnectClears() async {
        let service = makeConnected()
        let sut = ConnectionCoordinator(service: service)
        await sut.refresh()

        await sut.disconnect()

        #expect(sut.status.connected == false)
        #expect(sut.databases.isEmpty)
        #expect(service.disconnectCount == 1)
    }

    @Test("errors can be dismissed without re-fetching")
    func errorsDismiss() async {
        let service = StubConnectionService()
        service.statusError = .offline
        let sut = ConnectionCoordinator(service: service)
        await sut.refresh()

        sut.dismissError()

        #expect(sut.phase == .idle)
    }

    @Test("status decodes the backend's snake_case payload")
    func statusDecodes() throws {
        let json = #"""
        {"connected":true,"ready":true,"configurable":true,
         "workspace_name":"Mine","database_id":"db-9","database_title":"Journal"}
        """#
        let status = try JSONDecoder().decode(
            NotionConnectionStatus.self, from: Data(json.utf8)
        )
        #expect(status.workspaceName == "Mine")
        #expect(status.databaseId == "db-9")
        #expect(status.databaseTitle == "Journal")
    }

    @Test("a status payload never carries a token")
    func statusHasNoTokenField() throws {
        // Belt-and-braces: if someone adds one server-side, this decodes fine but the type
        // has nowhere to put it, and that is the point.
        let mirror = Mirror(reflecting: NotionConnectionStatus.disconnected)
        let names = mirror.children.compactMap(\.label).map { $0.lowercased() }
        #expect(!names.contains { $0.contains("token") || $0.contains("secret") })
    }
}

@Suite("Backend settings")
struct BackendSettingsTests {

    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "cp-tests-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.description)
        return suite
    }

    @Test("the built-in value is used when there is no override")
    func fallsBackToBundled() {
        let settings = BackendSettings(defaults: makeDefaults(), bundledValue: "http://localhost:8077")
        #expect(settings.baseURL?.absoluteString == "http://localhost:8077")
        #expect(settings.isUsingOverride == false)
    }

    /// The device case: localhost is the phone, so the build-time value is simply wrong there.
    @Test("an override wins over the built-in value")
    func overrideWins() {
        let settings = BackendSettings(defaults: makeDefaults(), bundledValue: "http://localhost:8077")
        settings.setOverride("http://192.168.1.20:8077")
        #expect(settings.baseURL?.absoluteString == "http://192.168.1.20:8077")
        #expect(settings.isUsingOverride)
    }

    @Test("clearing the override restores the built-in value")
    func clearingRestores() {
        let settings = BackendSettings(defaults: makeDefaults(), bundledValue: "http://localhost:8077")
        settings.setOverride("http://192.168.1.20:8077")
        settings.setOverride(nil)
        #expect(settings.baseURL?.absoluteString == "http://localhost:8077")
    }

    @Test("blank is treated as absent, not as a URL")
    func blankIsAbsent() {
        let settings = BackendSettings(defaults: makeDefaults(), bundledValue: "")
        #expect(settings.baseURL == nil, "an unconfigured backend is supported, not an error")
    }

    @Test("nonsense is rejected before it can be stored", arguments: [
        "not a url", "ftp://example.com", "localhost:8077", "://broken", "",
    ])
    func rejectsInvalid(raw: String) {
        #expect(BackendSettings.isValid(raw) == false)
    }

    @Test("ordinary URLs are accepted", arguments: [
        "http://localhost:8077", "http://192.168.1.20:8077", "https://api.example.com",
    ])
    func acceptsValid(raw: String) {
        #expect(BackendSettings.isValid(raw))
    }
}

@Suite("Unlinking a draft from its page")
@MainActor
struct UnlinkTests {

    @Test("unlinking forgets the page so the next sync makes a new one")
    func unlinkForgetsThePage() {
        let draft = EntryDraft()
        draft.updateRawText("An entry")
        let state = draft.syncState(for: .notion)
        state.markSynced(externalId: "a-page-we-should-never-have-claimed",
                         contentHash: draft.contentHash)

        state.unlinkFromDestination()

        #expect(state.externalId == nil)
        #expect(state.insertedBlockIds.isEmpty)
        #expect(draft.needsSync(to: .notion), "it now syncs afresh, to a page of its own")
    }

    @Test("unlinking leaves the entry itself untouched")
    func unlinkKeepsContent() {
        let draft = EntryDraft()
        draft.updateRawText("Words I wrote")
        let state = draft.syncState(for: .notion)
        state.markSynced(externalId: "page-1", contentHash: draft.contentHash)

        state.unlinkFromDestination()

        #expect(draft.content.rawText == "Words I wrote")
    }
}
