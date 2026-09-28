import ReplyKit
import SwiftUI

@main
struct ReplyKitDemoApp: App {
    @StateObject private var store: ReplyKitStore

    init() {
        let now = Date()
        let conversation = InboxConversation(id: "order-1284", subject: "Order update", preview: "Your order is on its way.", updatedAt: now, unreadCount: 1)
        let messages = [
            InboxMessage(id: "m1", conversationID: conversation.id, sender: "You", body: "Can you check my order?", sentAt: now.addingTimeInterval(-3600), isFromSupport: false),
            InboxMessage(id: "m2", conversationID: conversation.id, sender: "Support", body: "Your order has been processed and is on its way.", sentAt: now.addingTimeInterval(-1800), isFromSupport: true)
        ]
        let config = try! InboxConfiguration(appID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, appKey: "rk_live_" + String(repeating: "0", count: 64))
        _store = StateObject(wrappedValue: ReplyKitStore(configuration: config, service: MockInboxService(conversations: [conversation], messages: messages)))
    }

    var body: some Scene { WindowGroup { ReplyKitView(store: store, theme: InboxTheme(inboxTitle: "Support Inbox")) } }
}
