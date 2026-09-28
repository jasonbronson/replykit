import Combine
import Foundation

@MainActor
public final class ReplyKitStore: ObservableObject {
    @Published public private(set) var conversations: [InboxConversation] = []
    @Published public private(set) var messagesByConversation: [String: [InboxMessage]] = [:]
    @Published public private(set) var unreadCount = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var isLoadingMoreConversations = false
    @Published public private(set) var loadingMessageIDs: Set<String> = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var latestResponseEvent: InboxResponseEvent?
    @Published public var newConversationDraft = InboxDraft()
    @Published public var replyDrafts: [String: String] = [:]
    @Published public var replyAttachments: [String: [InboxAttachmentUpload]] = [:]

    private let configuration: InboxConfiguration
    private var service: any InboxService
    private var conversationCursor: String?
    private var messageCursors: [String: String] = [:]
    private var activeSessionGeneration = 0
    private var isRefreshingNow = false
    private var messageLoadsInProgress: Set<String> = []
    private var submissionToken: UUID?
    private var requestCancellations: [UUID: RequestCancellationBox] = [:]
    private var activeRequestKeys: [String: String] = [:]
    private var activeRequestDrafts: [String: InboxDraft] = [:]
    private var seenResponseEventIDs: Set<String> = []
    private var pollingTask: Task<Void, Never>?
    private var isForeground = false
    private let pollingInterval: Duration = .seconds(30)
    private let maximumPollingBackoff: Duration = .seconds(300)

    public init(configuration: InboxConfiguration, service: (any InboxService)? = nil) {
        self.configuration = configuration
        self.service = service ?? RESTInboxService(configuration: configuration)
    }

    public var hasMoreConversations: Bool { conversationCursor != nil }
    public func hasMoreMessages(for conversationID: String) -> Bool { messageCursors[conversationID] != nil }
    public func isLoadingMessages(for conversationID: String) -> Bool { loadingMessageIDs.contains(conversationID) }

    public func clearError() { errorMessage = nil }

    /// Returns the persistent installation UUID, creating it on first use.
    public func customerID() throws -> UUID { try configuration.customerID() }

    public func refresh() async {
        guard !isRefreshingNow else { return }
        isRefreshingNow = true; isRefreshing = true
        let generation = activeSessionGeneration
        if conversations.isEmpty { isLoading = true }
        defer { if generation == activeSessionGeneration { isRefreshingNow = false; isRefreshing = false; isLoading = false } }
        do {
            async let page = request { try await $0.conversations(cursor: nil) }
            async let count = request { try await $0.unreadCount() }
            let (result, unread) = try await (page, count)
            guard generation == activeSessionGeneration else { return }
            conversations = result.items.sorted { $0.updatedAt > $1.updatedAt }
            conversationCursor = result.nextCursor
            unreadCount = max(0, unread)
            errorMessage = nil
        } catch {
            guard generation == activeSessionGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func loadMoreConversations() async {
        guard let cursor = conversationCursor, !isLoadingMoreConversations else { return }
        isLoadingMoreConversations = true; let generation = activeSessionGeneration
        defer { if generation == activeSessionGeneration { isLoadingMoreConversations = false } }
        do {
            let page = try await request { try await $0.conversations(cursor: cursor) }
            guard generation == activeSessionGeneration else { return }
            let existing = Set(conversations.map(\.id))
            conversations.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            conversationCursor = page.nextCursor
        } catch { if generation == activeSessionGeneration { errorMessage = error.localizedDescription } }
    }

    public func loadMessages(for conversationID: String, loadMore: Bool = false) async {
        guard messageLoadsInProgress.insert(conversationID).inserted else { return }
        loadingMessageIDs.insert(conversationID)
        let cursor = loadMore ? messageCursors[conversationID] : nil
        if loadMore && cursor == nil { messageLoadsInProgress.remove(conversationID); loadingMessageIDs.remove(conversationID); return }
        let generation = activeSessionGeneration
        defer {
            if generation == activeSessionGeneration {
                messageLoadsInProgress.remove(conversationID)
                loadingMessageIDs.remove(conversationID)
            }
        }
        do {
            let page = try await request { try await $0.messages(conversationID: conversationID, cursor: cursor) }
            guard generation == activeSessionGeneration else { return }
            let old = loadMore ? (messagesByConversation[conversationID] ?? []) : []
            let existing = Set(old.map(\.id))
            messagesByConversation[conversationID] = (old + page.items.filter { !existing.contains($0.id) }).sorted { $0.sentAt < $1.sentAt }
            messageCursors[conversationID] = page.nextCursor
            if !loadMore {
                try Task.checkCancellation()
                try await request { try await $0.markRead(conversationID: conversationID) }
                guard generation == activeSessionGeneration else { return }
                if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
                    conversations[index].unreadCount = 0
                }
                await refreshUnreadCount()
            }
            errorMessage = nil
        } catch { if generation == activeSessionGeneration { errorMessage = error.localizedDescription } }
    }

    public func submitNewConversation() async {
        let submittedDraft = newConversationDraft
        let subject = submittedDraft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = submittedDraft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSubmitting else { return }
        guard !subject.isEmpty, !body.isEmpty else { errorMessage = "Enter a subject and message."; return }
        let attachments = submittedDraft.attachments
        isSubmitting = true
        let submissionToken = UUID(); self.submissionToken = submissionToken
        defer { if self.submissionToken == submissionToken { isSubmitting = false; self.submissionToken = nil } }
        let key = activeRequestDrafts["new"] == submittedDraft ? (activeRequestKeys["new"] ?? UUID().uuidString) : UUID().uuidString
        activeRequestKeys["new"] = key
        activeRequestDrafts["new"] = submittedDraft
        let generation = activeSessionGeneration
        do {
            let conversation = try await request { try await $0.createConversation(subject: subject, body: body, attachments: attachments, idempotencyKey: key) }
            guard generation == activeSessionGeneration else { return }
            conversations.insert(conversation, at: 0)
            if newConversationDraft == submittedDraft { newConversationDraft = InboxDraft() }
            activeRequestKeys.removeValue(forKey: "new"); activeRequestDrafts.removeValue(forKey: "new"); errorMessage = nil
            await refreshUnreadCount()
        } catch { if generation == activeSessionGeneration { errorMessage = error.localizedDescription } }
    }

    public func sendReply(to conversationID: String) async {
        let body = (replyDrafts[conversationID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSubmitting else { return }
        let attachments = replyAttachments[conversationID] ?? []
        guard !body.isEmpty || !attachments.isEmpty else { errorMessage = "Enter a message or attach a file before sending."; return }
        isSubmitting = true
        let submissionToken = UUID(); self.submissionToken = submissionToken
        defer { if self.submissionToken == submissionToken { isSubmitting = false; self.submissionToken = nil } }
        let keyName = "reply:\(conversationID)"
        let draft = InboxDraft(body: body, attachments: attachments)
        let key = activeRequestDrafts[keyName] == draft ? (activeRequestKeys[keyName] ?? UUID().uuidString) : UUID().uuidString
        activeRequestKeys[keyName] = key
        activeRequestDrafts[keyName] = draft
        let generation = activeSessionGeneration
        do {
            let message = try await request { try await $0.sendReply(conversationID: conversationID, body: body, attachments: draft.attachments, idempotencyKey: key) }
            guard generation == activeSessionGeneration else { return }
            messagesByConversation[conversationID, default: []].append(message)
            if InboxDraft(body: replyDrafts[conversationID] ?? "", attachments: replyAttachments[conversationID] ?? []) == draft {
                replyDrafts[conversationID] = ""; replyAttachments[conversationID] = []
            }
            activeRequestKeys.removeValue(forKey: keyName); activeRequestDrafts.removeValue(forKey: keyName); errorMessage = nil
            await refreshUnreadCount()
        } catch { if generation == activeSessionGeneration { errorMessage = error.localizedDescription } }
    }

    /// Clears cached inbox data and drafts. The installation UUID remains stable across logout.
    public func logout() {
        activeSessionGeneration += 1; pollingTask?.cancel(); pollingTask = nil; isForeground = false
        requestCancellations.values.forEach { $0.cancel() }; requestCancellations = [:]
        conversations = []; messagesByConversation = [:]; replyDrafts = [:]; replyAttachments = [:]; newConversationDraft = InboxDraft()
        unreadCount = 0; errorMessage = nil; latestResponseEvent = nil; seenResponseEventIDs = []
        activeRequestKeys = [:]; activeRequestDrafts = [:]; conversationCursor = nil; messageCursors = [:]
        messageLoadsInProgress = []; loadingMessageIDs = []; isLoadingMoreConversations = false; submissionToken = nil
        isLoading = false; isRefreshing = false; isRefreshingNow = false; isSubmitting = false
    }

    /// Host lifecycle hook: refresh on foreground and poll only while foregrounded.
    public func setForeground(_ foreground: Bool) {
        isForeground = foreground; pollingTask?.cancel(); pollingTask = nil
        guard foreground else { return }
        Task { await refresh() }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            var delay = pollingInterval
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                await self.refresh()
                if self.errorMessage == nil { delay = pollingInterval }
                else { delay = min(delay * 2, self.maximumPollingBackoff) }
            }
        }
    }

    /// Push forwarding hook. The host can pass a stable backend event/message ID, then trigger a refresh.
    public func handlePush(conversationID: String, messageID: String) async {
        guard !messageID.isEmpty, seenResponseEventIDs.insert(messageID).inserted else { return }
        latestResponseEvent = InboxResponseEvent(id: messageID, conversationID: conversationID, messageID: messageID)
        await refresh()
    }

    public func downloadAttachment(_ attachment: InboxAttachment) async throws -> URL {
        try await request { try await $0.downloadAttachment(attachment) }
    }

    private func request<Value: Sendable>(_ operation: @escaping @Sendable (any InboxService) async throws -> Value) async throws -> Value {
        let service = self.service
        let task = Task { try await operation(service) }
        let id = UUID()
        requestCancellations[id] = RequestCancellationBox { task.cancel() }
        defer { requestCancellations.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func refreshUnreadCount() async {
        let generation = activeSessionGeneration
        do { let count = try await request { try await $0.unreadCount() }; if generation == activeSessionGeneration { unreadCount = max(0, count) } }
        catch { if generation == activeSessionGeneration { errorMessage = error.localizedDescription } }
    }
}

private final class RequestCancellationBox: @unchecked Sendable {
    let cancel: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
}
