import Foundation

// MARK: - Transcription

/// `POST /stt` — audio in, transcript out.
///
/// Nothing here is responsible for durability. By the time this runs, the audio is already on
/// disk and committed, so every failure path below costs the user convenience and nothing
/// else. That separation is the point. See ADR-002.
public struct HTTPTranscriptionService: TranscriptionService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    private struct Response: Decodable {
        let text: String
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let response = try await client.upload(
            path: "stt",
            fileURL: request.audioURL,
            fieldName: "audio",
            fileName: request.audioURL.lastPathComponent,
            mimeType: "audio/m4a",
            // Transcription is a pure function of the audio, so the capture's own id is a
            // perfectly good idempotency key — a replayed request returns the same text.
            idempotencyKey: IdempotencyKey(attemptId: request.captureId.uuidString, step: "stt"),
            expecting: Response.self
        )
        return TranscriptionResult(
            captureId: request.captureId,
            text: response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Formatting

/// `POST /format` — groups and structures the user's own words.
///
/// The prompt lives server-side. The client's job is to send `rawText` unaltered and to
/// refuse to apply a result that no longer matches what the user has written.
public struct HTTPFormattingService: FormattingService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    private struct Payload: Encodable {
        let raw_text: String
        let draft_id: String
    }

    private struct Response: Decodable {
        let formatted_text: String
        let formatter_version: String
    }

    public func format(_ request: FormatRequest) async throws -> FormatResult {
        let response = try await client.postJSON(
            path: "format",
            body: Payload(raw_text: request.rawText, draft_id: request.draftId.uuidString),
            idempotencyKey: IdempotencyKey(attemptId: request.contentHash, step: "format"),
            expecting: Response.self
        )
        return FormatResult(
            draftId: request.draftId,
            formattedText: response.formatted_text,
            formatterVersion: response.formatter_version,
            // Echoed back so the caller can discard a stale result rather than let it
            // clobber newer typing. See ADR-016.
            sourceContentHash: request.contentHash
        )
    }
}

// MARK: - Notion

/// `POST /notion/*`. Every mutating call carries an idempotency key derived from the
/// `SyncState` attempt, so a lost response replays instead of writing twice. See ADR-003.
public struct NotionHTTPClient: NotionAPI {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    private struct EnsurePagePayload: Encodable {
        let entry_date: String
        let title: String?
        let existing_page_id: String?
    }

    private struct PageResponse: Decodable {
        let page_id: String
    }

    private struct FileResponse: Decodable {
        let file_id: String
    }

    private struct AttachedFilePayload: Encodable {
        let id: String
        let kind: String
    }

    private struct InsertPayload: Encodable {
        let page_id: String
        let formatted_text: String
        let attached_files: [AttachedFilePayload]
        let replace_block_ids: [String]
    }

    private struct InsertResponse: Decodable {
        let block_ids: [String]
    }

    private struct PropertiesPayload: Encodable {
        let page_id: String
        let title: String?
        let entry_date: String
    }

    private struct EmptyResponse: Decodable {}

    public func ensurePage(_ request: EnsurePageRequest) async throws -> String {
        let response = try await client.postJSON(
            path: "notion/ensure-page",
            body: EnsurePagePayload(
                // The calendar day, not the creation instant — this is what identifies the
                // page. See ADR-006.
                entry_date: request.entryDate.rawValue,
                title: request.title,
                existing_page_id: request.existingExternalId
            ),
            idempotencyKey: request.idempotencyKey,
            expecting: PageResponse.self
        )
        return response.page_id
    }

    public func uploadFile(_ request: UploadFileRequest) async throws -> String {
        let response = try await client.upload(
            path: "notion/upload-file",
            fileURL: request.fileURL,
            fieldName: "file",
            fileName: request.fileURL.lastPathComponent,
            mimeType: Self.mimeType(for: request.fileURL),
            fields: ["media_id": request.mediaId.uuidString],
            idempotencyKey: request.idempotencyKey,
            expecting: FileResponse.self
        )
        return response.file_id
    }

    public func insertContent(_ request: InsertContentRequest) async throws -> [String] {
        let response = try await client.postJSON(
            path: "notion/insert-content",
            body: InsertPayload(
                page_id: request.pageId,
                formatted_text: request.formattedText,
                attached_files: request.attachedFiles.map {
                    AttachedFilePayload(id: $0.id, kind: $0.kind.rawValue)
                },
                // Blocks from an interrupted attempt, so the server replaces rather than
                // appends. See ADR-005.
                replace_block_ids: request.previouslyInsertedBlockIds
            ),
            idempotencyKey: request.idempotencyKey,
            expecting: InsertResponse.self
        )
        return response.block_ids
    }

    public func updateProperties(_ request: UpdatePropertiesRequest) async throws {
        _ = try await client.postJSON(
            path: "notion/update-props",
            body: PropertiesPayload(
                page_id: request.pageId,
                title: request.title,
                entry_date: request.entryDate.rawValue
            ),
            idempotencyKey: request.idempotencyKey,
            expecting: EmptyResponse.self
        )
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "mov": "video/quicktime"
        case "mp4": "video/mp4"
        case "m4a": "audio/m4a"
        default: "application/octet-stream"
        }
    }
}
