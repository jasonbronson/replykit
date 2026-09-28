import XCTest
@testable import ReplyKit

@MainActor
final class ReplyKitStoreTests: XCTestCase {
    func testSubmitClearsDraftOnlyAfterSuccessAndLogoutKeepsIdentity() async throws {
        let service = MockInboxService()
        let store = ReplyKitStore(configuration: testConfiguration(), service: service)
        store.newConversationDraft = InboxDraft(subject: "Question", body: "Please help")

        await store.submitNewConversation()
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertEqual(store.newConversationDraft, InboxDraft())
        let customerID = try store.customerID()

        store.replyDrafts[store.conversations[0].id] = "private draft"
        store.logout()
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(store.replyDrafts.isEmpty)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(try store.customerID(), customerID)
    }

    func testOpeningConversationRefreshesAggregateUnreadCount() async {
        let conversation = InboxConversation(id: "c1", subject: "Help", preview: "Reply", updatedAt: .now, unreadCount: 3)
        let message = InboxMessage(id: "m1", conversationID: "c1", sender: "Support", body: "Reply", sentAt: .now, isFromSupport: true)
        let service = MockInboxService(conversations: [conversation], messages: [message])
        let store = ReplyKitStore(configuration: testConfiguration(), service: service)

        await store.refresh()
        XCTAssertEqual(store.unreadCount, 3)
        await store.loadMessages(for: "c1")
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testLogoutPreventsLateRefreshFromRestoringPreviousSessionData() async {
        let store = ReplyKitStore(configuration: testConfiguration(), service: DelayedInboxService())
        let refresh = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        store.logout()
        await refresh.value
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertEqual(store.unreadCount, 0)
    }

    func testFailedSubmissionPreservesDraftAndReusesIdempotencyKey() async {
        let service = FailingInboxService()
        let store = ReplyKitStore(configuration: testConfiguration(), service: service)
        store.newConversationDraft = InboxDraft(subject: "Question", body: "Draft survives")

        await store.submitNewConversation()
        await store.submitNewConversation()

        XCTAssertEqual(store.newConversationDraft.body, "Draft survives")
        let keys = await service.keys()
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first, keys.last)
    }

    func testFailedSubmissionPreservesSelectedAttachmentsAndRetryKey() async {
        let service = FailingInboxService()
        let store = ReplyKitStore(configuration: testConfiguration(), service: service)
        let attachment = InboxAttachmentUpload(filename: "receipt.pdf", contentType: "application/pdf", data: Data([1, 2, 3]))
        store.newConversationDraft = InboxDraft(subject: "Question", body: "See attached", attachments: [attachment])

        await store.submitNewConversation()
        await store.submitNewConversation()

        XCTAssertEqual(store.newConversationDraft.attachments, [attachment])
        let keys = await service.keys()
        let filenames = await service.uploadedFilenames()
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first, keys.last)
        XCTAssertEqual(filenames, ["receipt.pdf", "receipt.pdf"])
    }
}

private func testConfiguration() -> InboxConfiguration {
    try! InboxConfiguration(appID: UUID(uuidString: "4ccca23f-1397-4fd4-9b31-2e15d4de3c81")!, appKey: "rk_live_" + String(repeating: "b", count: 64), identityStore: StoreTestIdentityStore())
}

private final class StoreTestIdentityStore: ReplyKitIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: UUID?
    func customerID(for appID: UUID) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        if let identity { return identity }
        let newIdentity = UUID(); identity = newIdentity; return newIdentity
    }
}

private actor FailingInboxService: InboxService {
    private var seenKeys: [String] = []
    private var seenFilenames: [String] = []
    func conversations(cursor: String?) async throws -> InboxPage<InboxConversation> { InboxPage(items: []) }
    func messages(conversationID: String, cursor: String?) async throws -> InboxPage<InboxMessage> { InboxPage(items: []) }
    func createConversation(subject: String, body: String, idempotencyKey: String) async throws -> InboxConversation {
        seenKeys.append(idempotencyKey); throw InboxError.httpStatus(503, nil)
    }
    func createConversation(subject: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxConversation {
        seenKeys.append(idempotencyKey); seenFilenames.append(contentsOf: attachments.map(\.filename))
        throw InboxError.httpStatus(503, nil)
    }
    func sendReply(conversationID: String, body: String, idempotencyKey: String) async throws -> InboxMessage { throw InboxError.httpStatus(503, nil) }
    func markRead(conversationID: String) async throws {}
    func unreadCount() async throws -> Int { 0 }
    func keys() -> [String] { seenKeys }
    func uploadedFilenames() -> [String] { seenFilenames }
}

private actor DelayedInboxService: InboxService {
    func conversations(cursor: String?) async throws -> InboxPage<InboxConversation> {
        try await Task.sleep(for: .milliseconds(100))
        return InboxPage(items: [InboxConversation(id: "old", subject: "Old", preview: "stale", updatedAt: .now)])
    }
    func messages(conversationID: String, cursor: String?) async throws -> InboxPage<InboxMessage> { InboxPage(items: []) }
    func createConversation(subject: String, body: String, idempotencyKey: String) async throws -> InboxConversation { throw InboxError.invalidResponse }
    func sendReply(conversationID: String, body: String, idempotencyKey: String) async throws -> InboxMessage { throw InboxError.invalidResponse }
    func markRead(conversationID: String) async throws {}
    func unreadCount() async throws -> Int { 0 }
}
