# ReplyKit

ReplyKit is a reusable SwiftUI support inbox. It lets customers send feedback, follow conversations, attach files, and see support replies inside an existing iOS app.

Visit [replykit.bronson.dev](https://replykit.bronson.dev) to learn more, register for an account, and access the support dashboard.

## Add to an app

In Xcode, choose **File → Add Package Dependencies…** and add the published Git repository, then select the `ReplyKit` library product. For local development, choose **Add Local…** and select this package folder.

Create one store for your app and present `ReplyKitView` where it fits your navigation:

```swift
import Foundation
import ReplyKit

let configuration = try InboxConfiguration(
    appID: UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!, // stable app ID from the admin panel
    appKey: "rk_live_REPLACE_WITH_APP_KEY"
)
let inboxStore = ReplyKitStore(configuration: configuration)

// Embed in your SwiftUI view or present in a sheet.
ReplyKitView(store: inboxStore, theme: InboxTheme(inboxTitle: "Help"))
```

The initializer validates the app key, so replace the example value with the key from the admin panel's **Create app** flow. `InboxConfiguration` takes only the stable app ID and app key; the API URL and paging and polling behavior are set inside the package. The API URL is `https://replykit.bronson.dev/v1/api/`, using the default HTTPS port (443).

## Customer identity

ReplyKit generates a customer UUID on the first API request and stores it in the host app's Keychain, scoped to the app ID and host bundle identifier. It sends the app key and customer UUID with inbox requests. Keeping the app ID stable preserves the UUID when the app key is rotated. Keychain data may survive reinstall, but Apple does not guarantee this; a device reset or Keychain clearing can create a new UUID.

`ReplyKitStore.customerID()` returns the UUID if the host needs to inspect it. `ReplyKitStore.logout()` clears cached conversations and drafts but keeps the installation UUID.

## Attachments

Customers can attach up to 10 JPEG, PNG, GIF, WebP, PDF, or plain-text files per message, up to 10 MiB per file and 25 MiB total. ReplyKit retains selected files in the draft if sending fails. Received attachments are downloaded through the configured service and previewed from a temporary local copy on iOS.

## Refresh and notifications

The inbox refreshes when shown and when the app enters the foreground. ReplyKit polls every 30 seconds while foregrounded, stops in the background or after `logout()`, and backs off after errors up to five minutes. The page size is 30. These values are fixed inside the package.

The host can observe `unreadCount` and `latestResponseEvent`, forward a relevant push with `handlePush(conversationID:messageID:)`, and report foreground changes through `setForeground(_:)`. Push registration and delivery belong to the host app and backend. ReplyKit does not request notification permission.

## Customization and examples

Set basic colors and labels with `InboxTheme`. Use `ConversationView` or `NewMessageView` directly if the host needs to manage navigation itself. `MockInboxService` is available for previews and examples.

The iOS SwiftUI demo is in `Examples/ReplyKitDemo-iOS`. Open its Xcode project and run the `ReplyKitDemo` scheme; it uses seeded conversations and makes no network requests. The macOS demo can be run from the package directory with:

```sh
swift run --package-path Examples/ReplyKitDemo ReplyKitDemo
```

ReplyKit supports iOS 16+ and macOS 14+. The backend contract lives separately in [API_CONTRACT.md](API_CONTRACT.md).
