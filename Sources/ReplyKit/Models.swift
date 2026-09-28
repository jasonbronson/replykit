import Foundation
import Security

public struct InboxPage<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let nextCursor: String?
    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct InboxConversation: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var subject: String
    public var preview: String
    public var updatedAt: Date
    public var unreadCount: Int
    public var status: String
    public init(id: String, subject: String, preview: String, updatedAt: Date, unreadCount: Int = 0, status: String = "open") {
        self.id = id; self.subject = subject; self.preview = preview; self.updatedAt = updatedAt
        self.unreadCount = unreadCount; self.status = status
    }
}

public struct InboxMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let sender: String
    public let body: String
    public let sentAt: Date
    public let isFromSupport: Bool
    public var attachments: [InboxAttachment]
    public init(id: String, conversationID: String, sender: String, body: String, sentAt: Date, isFromSupport: Bool, attachments: [InboxAttachment] = []) {
        self.id = id; self.conversationID = conversationID; self.sender = sender; self.body = body
        self.sentAt = sentAt; self.isFromSupport = isFromSupport
        self.attachments = attachments
    }
}

public struct InboxAttachment: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let filename: String
    /// Relative or absolute API URL. ReplyKit downloads it through the configured API.
    public let url: URL
    public let contentType: String
    public let size: Int64
    public let senderType: String?
    public let senderID: String?
    public init(id: String, filename: String, url: URL, contentType: String, size: Int64, senderType: String? = nil, senderID: String? = nil) {
        self.id = id; self.filename = filename; self.url = url; self.contentType = contentType; self.size = size
        self.senderType = senderType; self.senderID = senderID
    }
}

/// A file selected by the user and retained in the draft until the message is accepted.
public struct InboxAttachmentUpload: Hashable, Sendable {
    public let filename: String
    public let contentType: String
    public let data: Data
    public init(filename: String, contentType: String, data: Data) {
        self.filename = filename; self.contentType = contentType; self.data = data
    }
}

public struct InboxDraft: Equatable, Sendable {
    public var subject: String
    public var body: String
    public var attachments: [InboxAttachmentUpload]
    public init(subject: String = "", body: String = "", attachments: [InboxAttachmentUpload] = []) { self.subject = subject; self.body = body; self.attachments = attachments }
}

public struct InboxResponseEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let conversationID: String
    public let messageID: String
    public let receivedAt: Date
    public init(id: String, conversationID: String, messageID: String, receivedAt: Date = .now) {
        self.id = id; self.conversationID = conversationID; self.messageID = messageID; self.receivedAt = receivedAt
    }
}

public struct InboxConfiguration: Sendable {
    public let appID: UUID
    public let appKey: String
    private let identityStore: any ReplyKitIdentityStore

    public init(appID: UUID, appKey: String) throws {
        try self.init(appID: appID, appKey: appKey, identityStore: KeychainReplyKitIdentityStore())
    }

    init(appID: UUID, appKey: String, identityStore: any ReplyKitIdentityStore) throws {
        let keySuffix = appKey.dropFirst("rk_live_".count)
        guard appKey.hasPrefix("rk_live_"), keySuffix.unicodeScalars.count == 64,
              keySuffix.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
            throw InboxError.invalidInput("Use the app key generated in the ReplyKit admin panel.")
        }
        self.appID = appID; self.appKey = appKey
        self.identityStore = identityStore
    }

    /// Returns the stable installation identity, generating and persisting it on first use.
    public func customerID() throws -> UUID { try identityStore.customerID(for: appID) }
}

/// Supplies one persistent customer identity per stable app ID. Logout intentionally does not erase it.
protocol ReplyKitIdentityStore: Sendable {
    func customerID(for appID: UUID) throws -> UUID
}

/// Stores the customer UUID in the host app's Keychain, separately for each stable ReplyKit app ID.
final class KeychainReplyKitIdentityStore: ReplyKitIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private let service = "com.replykit.customer-identity.\(Bundle.main.bundleIdentifier ?? "default")"

    public init() {}

    public func customerID(for appID: UUID) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        var query = [String: Any](dictionaryLiteral: (kSecClass as String, kSecClassGenericPassword),
                                  (kSecAttrService as String, service),
                                  (kSecAttrAccount as String, appID.uuidString),
                                  (kSecReturnData as String, true),
                                  (kSecMatchLimit as String, kSecMatchLimitOne))
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) { return id }
        guard status == errSecItemNotFound else { throw InboxError.identityPersistence(status) }

        let id = UUID()
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = Data(id.uuidString.utf8)
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return id }
        if addStatus == errSecDuplicateItem {
            let readQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: appID.uuidString,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var duplicateResult: CFTypeRef?
            let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &duplicateResult)
            if readStatus == errSecSuccess, let data = duplicateResult as? Data,
               let value = String(data: data, encoding: .utf8), let existingID = UUID(uuidString: value) { return existingID }
            throw InboxError.identityPersistence(readStatus)
        }
        throw InboxError.identityPersistence(addStatus)
    }
}

public struct InboxTheme: Sendable {
    public var tint: ColorToken
    public var inboxTitle: String
    public var newMessageTitle: String
    public var emptyTitle: String
    public init(tint: ColorToken = .blue, inboxTitle: String = "Inbox", newMessageTitle: String = "New message", emptyTitle: String = "No conversations yet") {
        self.tint = tint; self.inboxTitle = inboxTitle; self.newMessageTitle = newMessageTitle; self.emptyTitle = emptyTitle
    }
}

/// A SwiftUI-independent color choice that works across Swift package boundaries.
public enum ColorToken: String, Sendable { case blue, indigo, teal, green, orange, purple, red }
