import Foundation
import XCTest
@testable import ReplyKit

final class RESTInboxServiceTests: XCTestCase {
    func testConversationRouteAddsCursorAndAppAndCustomerIdentityHeaders() async throws {
        InboxURLProtocol.responseData = Data(#"{"items":[],"nextCursor":null}"#.utf8)
        InboxURLProtocol.lastRequest = nil
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [InboxURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let configuration = try makeConfiguration()
        let service = RESTInboxService(configuration: configuration, session: session)

        let page = try await service.conversations(cursor: "next-page")
        let request = try XCTUnwrap(InboxURLProtocol.lastRequest)
        XCTAssertTrue(request.url?.absoluteString.contains("conversations?limit=30&cursor=next-page") == true)
        XCTAssertEqual(request.url?.host, "localhost")
        XCTAssertEqual(request.url?.port, 8014)
        XCTAssertEqual(request.url?.path, "/v1/api/conversations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-ReplyKit-App-Key"), testAppKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-ReplyKit-Customer-ID"), try configuration.customerID().uuidString.lowercased())
        XCTAssertTrue(page.items.isEmpty)
    }

    func testMarkReadAcceptsNoContentResponse() async throws {
        InboxURLProtocol.statusCode = 204
        InboxURLProtocol.responseData = Data()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [InboxURLProtocol.self]
        let service = RESTInboxService(configuration: try makeConfiguration(), session: URLSession(configuration: sessionConfiguration))

        try await service.markRead(conversationID: "thread/1")
        XCTAssertEqual(InboxURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(InboxURLProtocol.lastRequest?.url?.path, "/v1/api/conversations/thread%2F1/read")
    }

    func testCustomerIdentitySurvivesAppKeyRotationAndIsolatesApps() throws {
        let identityStore = TestIdentityStore()
        let first = try makeConfiguration(identityStore: identityStore)
        let rotated = try makeConfiguration(appKey: "rk_live_" + String(repeating: "c", count: 64), identityStore: identityStore)
        let anotherApp = try makeConfiguration(appID: UUID(), identityStore: identityStore)

        XCTAssertEqual(try first.customerID(), try rotated.customerID())
        XCTAssertNotEqual(try first.customerID(), try anotherApp.customerID())
    }

    private func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testCreateConversationUsesProposedRequestShapeAndIdempotencyHeader() async throws {
        InboxURLProtocol.statusCode = 200
        InboxURLProtocol.responseData = Data(#"{"id":"c1","subject":"Help","preview":"Hello","updatedAt":"2025-01-01T00:00:00Z","unreadCount":0,"status":"open"}"#.utf8)
        InboxURLProtocol.lastRequest = nil
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [InboxURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let service = RESTInboxService(configuration: try makeConfiguration(), session: session)

        let result = try await service.createConversation(subject: "Help", body: "Hello", idempotencyKey: "request-key")
        let request = try XCTUnwrap(InboxURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/api/conversations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "request-key")
        let bodyData = try XCTUnwrap(request.httpBody ?? readBody(from: request.httpBodyStream))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: bodyData) as? [String: String], ["subject": "Help", "body": "Hello"])
        XCTAssertEqual(result.id, "c1")
    }

    func testCreateConversationUploadsRepeatedAttachmentFieldsAsMultipart() async throws {
        InboxURLProtocol.statusCode = 200
        InboxURLProtocol.responseData = Data(#"{"id":"c1","subject":"Help","preview":"See file","updatedAt":"2025-01-01T00:00:00Z","unreadCount":0,"status":"open"}"#.utf8)
        InboxURLProtocol.lastRequest = nil
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [InboxURLProtocol.self]
        let service = RESTInboxService(configuration: try makeConfiguration(), session: URLSession(configuration: sessionConfiguration))
        let upload = InboxAttachmentUpload(filename: "photo.jpg", contentType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))

        _ = try await service.createConversation(subject: "Help", body: "See file", attachments: [upload, upload], idempotencyKey: "upload-key")
        let request = try XCTUnwrap(InboxURLProtocol.lastRequest)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-ReplyKit-App-Key"), testAppKey)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-ReplyKit-Customer-ID"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "upload-key")
        let body = try XCTUnwrap(request.httpBody ?? readBody(from: request.httpBodyStream))
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"subject\""))
        XCTAssertTrue(bodyText.contains("name=\"body\""))
        XCTAssertEqual(bodyText.components(separatedBy: "name=\"attachments\"; filename=\"photo.jpg\"").count - 1, 2)
    }

    func testAttachmentDownloadUsesOpaqueIDRouteWithIdentityHeadersAndWritesLocalFile() async throws {
        InboxURLProtocol.statusCode = 200
        InboxURLProtocol.responseData = Data("image bytes".utf8)
        InboxURLProtocol.lastRequest = nil
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [InboxURLProtocol.self]
        let service = RESTInboxService(configuration: try makeConfiguration(), session: URLSession(configuration: sessionConfiguration))
        let attachment = InboxAttachment(id: "opaque-id", filename: "photo.jpg", url: URL(string: "https://untrusted.example/file")!, contentType: "image/jpeg", size: 11, senderType: "admin", senderID: "admin-uuid")

        let file = try await service.downloadAttachment(attachment)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(InboxURLProtocol.lastRequest?.url?.absoluteString, "http://localhost:8014/v1/api/attachments/opaque-id")
        XCTAssertEqual(InboxURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-ReplyKit-App-Key"), testAppKey)
        XCTAssertNotNil(InboxURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-ReplyKit-Customer-ID"))
        XCTAssertEqual(try Data(contentsOf: file), Data("image bytes".utf8))
    }
}

private let testAppKey = "rk_live_" + String(repeating: "a", count: 64)
private let testAppID = UUID(uuidString: "15d57426-f66d-440c-b30c-967d3f58ee3c")!

private func makeConfiguration(appKey: String = testAppKey, appID: UUID = testAppID, identityStore: TestIdentityStore = TestIdentityStore()) throws -> InboxConfiguration {
    try InboxConfiguration(appID: appID, appKey: appKey, identityStore: identityStore)
}

private final class TestIdentityStore: ReplyKitIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [UUID: UUID] = [:]
    func customerID(for appID: UUID) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        if let identity = identities[appID] { return identity }
        let identity = UUID(); identities[appID] = identity; return identity
    }
}

private final class InboxURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
