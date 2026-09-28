import Foundation

public protocol InboxService: Sendable {
    func conversations(cursor: String?) async throws -> InboxPage<InboxConversation>
    func messages(conversationID: String, cursor: String?) async throws -> InboxPage<InboxMessage>
    func createConversation(subject: String, body: String, idempotencyKey: String) async throws -> InboxConversation
    func sendReply(conversationID: String, body: String, idempotencyKey: String) async throws -> InboxMessage
    func createConversation(subject: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxConversation
    func sendReply(conversationID: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxMessage
    func downloadAttachment(_ attachment: InboxAttachment) async throws -> URL
    func markRead(conversationID: String) async throws
    func unreadCount() async throws -> Int
}

public extension InboxService {
    /// Keeps existing host implementations source-compatible. Services with upload support should override this.
    func createConversation(subject: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxConversation {
        guard attachments.isEmpty else { throw InboxError.attachmentsUnsupported }
        return try await createConversation(subject: subject, body: body, idempotencyKey: idempotencyKey)
    }
    func sendReply(conversationID: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxMessage {
        guard attachments.isEmpty else { throw InboxError.attachmentsUnsupported }
        return try await sendReply(conversationID: conversationID, body: body, idempotencyKey: idempotencyKey)
    }
    func downloadAttachment(_ attachment: InboxAttachment) async throws -> URL { throw InboxError.attachmentsUnsupported }
}

public enum InboxError: Error, LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int, String?)
    case unauthorized
    case invalidInput(String)
    case identityPersistence(OSStatus)
    case decoding
    case attachmentsUnsupported

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid response."
        case .httpStatus(let status, let message): message ?? "The request failed (HTTP \(status))."
        case .unauthorized: "This app key or customer identity could not access the inbox."
        case .invalidInput(let message): message
        case .identityPersistence: "ReplyKit could not save this installation's customer identity."
        case .decoding: "The server response could not be read."
        case .attachmentsUnsupported: "Attachments are not supported by this service."
        }
    }
}
