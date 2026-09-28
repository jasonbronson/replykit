# ReplyKit

ReplyKit is a reusable SwiftUI support inbox for an existing app. Users can submit a subject and message, attach files, read and reply to private support conversations, and see unread status. It is an API-backed in-app inbox; it does not send email or expose email addresses.

## Add to an app

In Xcode, choose **File → Add Package Dependencies…** and enter this repository URL. Select the `ReplyKit` library product. For local development, add the package directory directly.

Create one store and embed `ReplyKitView` where it fits your app's navigation. ReplyKit currently sends requests to its package-defined local API URL, `http://localhost:8087/v1/api/`; the host app does not configure the server URL.

```swift
import Foundation
import ReplyKit

let configuration = try InboxConfiguration(
    appID: UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!, // use the stable app ID from the admin panel
    appKey: "rk_live_<64 lowercase hex characters>"
)
let inboxStore = ReplyKitStore(configuration: configuration)

// In a SwiftUI screen:
ReplyKitView(store: inboxStore, theme: InboxTheme(inboxTitle: "Help"))
```

The app ID and app key come from the admin panel's **Create app** flow. ReplyKit generates a customer UUID on the first API request and stores it in the host app's Keychain, scoped to the stable app ID and the host app's bundle identifier. It sends `X-ReplyKit-App-Key` and `X-ReplyKit-Customer-ID` on every user API request, including attachment upload and download. The app ID is not sent; the API resolves it from the app key. Keeping the app ID stable means rotating the app key does not change the customer UUID. `try inboxStore.customerID()` lets the host inspect the generated identity if needed. `inboxStore.logout()` clears local inbox content and drafts but deliberately keeps the installation UUID stable. Keychain data can survive reinstall on some devices, but the OS does not guarantee that; device resets, app identity/access-group changes, or Keychain clearing can create a new UUID.

`ReplyKitStore` exposes observable `unreadCount` and `latestResponseEvent`. The host can refresh on app foreground through `setForeground(_:)`; the view also refreshes when shown. ReplyKit polls every 30 seconds while foregrounded, stops on background/logout, and backs off after errors up to 5 minutes. Requests fetch 30 items per page. These values are fixed inside the package. A host can forward a relevant push using `handlePush(conversationID:messageID:)`. The host/backend must implement push registration and delivery. The package never asks for notification permission.

Customize the tint and basic labels with `InboxTheme`. Use `ConversationView` or `NewMessageView` directly when you need to compose your own navigation flow. Inject any `InboxService` implementation for custom APIs or previews; `MockInboxService` is included for demos.

## API routes and payloads

See [API_CONTRACT.md](API_CONTRACT.md) for request/response JSON, route names, paging, unread semantics, identity headers, idempotency, and push integration. `RESTInboxService` uses these routes under `/v1/api/`:

- `GET /conversations`
- `GET /conversations/{id}/messages`
- `POST /conversations`
- `POST /conversations/{id}/messages`
- `PUT /conversations/{id}/read`
- `GET /unread-count`

The server URL is defined in `Sources/ReplyKit/RESTInboxService.swift`. To use a hosted server or a physical device, update that package constant to a URL reachable by the app; `localhost` refers to the device itself outside the iOS Simulator.

The app key and customer UUID identify the app and installation. They are included in the host app and are not secret credentials. The backend must scope each conversation, message, and attachment query by both values, and implement idempotency for `Idempotency-Key`. The same key is retained for retry after an ambiguous submission failure and discarded after success or local logout.

Messages support up to 10 JPEG, PNG, GIF, WebP, PDF, or plain text files (10 MiB each, 25 MiB total). ReplyKit uploads selected files as multipart form data and keeps them in the draft after a failed send. It downloads received attachments from the configured API using the same app and customer identity headers, then previews the local temporary file on iOS. The backend must enforce file validation and attachment ownership; see `API_CONTRACT.md`.

## Example host

`Examples/ReplyKitDemo-iOS` is the runnable iOS SwiftUI host project. It uses seeded mock conversations and requires no backend or credentials. An additional macOS SwiftUI demo is available through SwiftPM; from the package directory run:

```sh
swift run --package-path Examples/ReplyKitDemo ReplyKitDemo
```

The library supports iOS 16+ and macOS 14+.

For the iOS mock host, open `Examples/ReplyKitDemo-iOS/ReplyKitDemo.xcodeproj`, choose the `ReplyKitDemo` scheme, and run it on an iOS 16+ simulator or device. It uses seeded in-memory conversations and does not call the configured placeholder URL.
