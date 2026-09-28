import Foundation

/// In-memory service for previews and example hosts. Data is isolated per instance.
public actor MockInboxService: InboxService {
    private var conversations: [InboxConversation]
    private var messagesByConversation: [String: [InboxMessage]]
    private let pageSize: Int
    private var conversationsByIdempotencyKey: [String: InboxConversation] = [:]
    private var attachmentData: [String: (InboxAttachment, Data)] = [:]

    public init(conversations: [InboxConversation] = [], messages: [InboxMessage] = [], pageSize: Int = 30) {
        self.conversations = conversations.sorted { $0.updatedAt > $1.updatedAt }
        self.messagesByConversation = Dictionary(grouping: messages, by: \.conversationID)
        self.pageSize = max(1, pageSize)
    }

    public func conversations(cursor: String?) async throws -> InboxPage<InboxConversation> {
        let offset = Int(cursor ?? "0") ?? 0
        let slice = Array(conversations.dropFirst(offset).prefix(pageSize))
        let next = offset + slice.count < conversations.count ? String(offset + slice.count) : nil
        return InboxPage(items: slice, nextCursor: next)
    }
    public func messages(conversationID: String, cursor: String?) async throws -> InboxPage<InboxMessage> {
        let all = (messagesByConversation[conversationID] ?? []).sorted { $0.sentAt < $1.sentAt }
        let offset = Int(cursor ?? "0") ?? 0
        let slice = Array(all.dropFirst(offset).prefix(pageSize))
        let next = offset + slice.count < all.count ? String(offset + slice.count) : nil
        return InboxPage(items: slice, nextCursor: next)
    }
    public func createConversation(subject: String, body: String, idempotencyKey: String) async throws -> InboxConversation {
        try await createConversation(subject: subject, body: body, attachments: [], idempotencyKey: idempotencyKey)
    }
    public func createConversation(subject: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxConversation {
        if let existing = conversationsByIdempotencyKey[idempotencyKey] { return existing }
        let id = UUID().uuidString
        let messageAttachments = makeAttachments(attachments)
        let message = InboxMessage(id: UUID().uuidString, conversationID: id, sender: "You", body: body, sentAt: .now, isFromSupport: false, attachments: messageAttachments)
        let conversation = InboxConversation(id: id, subject: subject, preview: body, updatedAt: .now)
        conversations.insert(conversation, at: 0); messagesByConversation[id] = [message]
        conversationsByIdempotencyKey[idempotencyKey] = conversation
        return conversation
    }
    public func sendReply(conversationID: String, body: String, idempotencyKey: String) async throws -> InboxMessage {
        try await sendReply(conversationID: conversationID, body: body, attachments: [], idempotencyKey: idempotencyKey)
    }
    public func sendReply(conversationID: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxMessage {
        if let existing = messagesByConversation[conversationID]?.first(where: { $0.id == idempotencyKey }) { return existing }
        let message = InboxMessage(id: idempotencyKey, conversationID: conversationID, sender: "You", body: body, sentAt: .now, isFromSupport: false, attachments: makeAttachments(attachments))
        messagesByConversation[conversationID, default: []].append(message)
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].preview = body; conversations[index].updatedAt = .now
        }
        return message
    }
    public func markRead(conversationID: String) async throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].unreadCount = 0
    }
    public func unreadCount() async throws -> Int { conversations.reduce(0) { $0 + $1.unreadCount } }

    public func downloadAttachment(_ attachment: InboxAttachment) async throws -> URL {
        guard let (_, data) = attachmentData[attachment.id] else { throw InboxError.invalidInput("Attachment not found.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReplyKit-Mock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(URL(fileURLWithPath: attachment.filename).lastPathComponent)
        try data.write(to: file, options: .atomic)
        return file
    }

    private func makeAttachments(_ uploads: [InboxAttachmentUpload]) -> [InboxAttachment] {
        uploads.map { upload in
            let attachment = InboxAttachment(id: UUID().uuidString, filename: URL(fileURLWithPath: upload.filename).lastPathComponent,
                                             url: URL(string: "/attachments/mock")!, contentType: upload.contentType, size: Int64(upload.data.count))
            attachmentData[attachment.id] = (attachment, upload.data)
            return attachment
        }
    }
}
