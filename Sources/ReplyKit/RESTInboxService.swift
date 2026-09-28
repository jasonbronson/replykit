import Foundation

/// REST adapter. Route and payload shapes are documented in API_CONTRACT.md.
public actor RESTInboxService: InboxService {
    private let baseURL = URL(string: "http://localhost:8014/v1/api/")!
    private let pageSize = 30
    private let configuration: InboxConfiguration
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configuration: InboxConfiguration, session: URLSession = .shared) {
        self.configuration = configuration; self.session = session
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; self.encoder = encoder
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; self.decoder = decoder
    }

    public func conversations(cursor: String?) async throws -> InboxPage<InboxConversation> {
        try await request("GET", path: "conversations", query: pageQuery(cursor), body: Optional<Int>.none)
    }
    public func messages(conversationID: String, cursor: String?) async throws -> InboxPage<InboxMessage> {
        try await request("GET", path: "conversations/\(segment(conversationID))/messages", query: pageQuery(cursor), body: Optional<Int>.none)
    }
    public func createConversation(subject: String, body: String, idempotencyKey: String) async throws -> InboxConversation {
        try await createConversation(subject: subject, body: body, attachments: [], idempotencyKey: idempotencyKey)
    }
    public func sendReply(conversationID: String, body: String, idempotencyKey: String) async throws -> InboxMessage {
        try await sendReply(conversationID: conversationID, body: body, attachments: [], idempotencyKey: idempotencyKey)
    }
    public func createConversation(subject: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxConversation {
        if attachments.isEmpty {
            return try await request("POST", path: "conversations", body: CreateConversationBody(subject: subject, body: body), idempotencyKey: idempotencyKey)
        }
        let data = try await sendMultipart(path: "conversations", fields: [("subject", subject), ("body", body)], attachments: attachments, idempotencyKey: idempotencyKey)
        guard let result = try? decoder.decode(InboxConversation.self, from: data) else { throw InboxError.decoding }
        return result
    }
    public func sendReply(conversationID: String, body: String, attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> InboxMessage {
        let path = "conversations/\(segment(conversationID))/messages"
        if attachments.isEmpty { return try await request("POST", path: path, body: SendMessageBody(body: body), idempotencyKey: idempotencyKey) }
        let data = try await sendMultipart(path: path, fields: [("body", body)], attachments: attachments, idempotencyKey: idempotencyKey)
        guard let result = try? decoder.decode(InboxMessage.self, from: data) else { throw InboxError.decoding }
        return result
    }
    public func downloadAttachment(_ attachment: InboxAttachment) async throws -> URL {
        // Use the documented same-origin route by opaque ID; never attach credentials to a server-provided URL.
        let data = try await send("GET", path: "attachments/\(segment(attachment.id))", body: Optional<Int>.none)
        let safeName = URL(fileURLWithPath: attachment.filename).lastPathComponent
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplyKit-\(UUID().uuidString)")
            .appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return destination
    }
    public func markRead(conversationID: String) async throws {
        try await perform("PUT", path: "conversations/\(segment(conversationID))/read", body: Optional<Int>.none)
    }
    public func unreadCount() async throws -> Int {
        let response: UnreadCountResponse = try await request("GET", path: "unread-count", body: Optional<Int>.none)
        return response.unreadCount
    }

    private func pageQuery(_ cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(pageSize))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }
    private func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? value }

    private func request<Response: Decodable, Body: Encodable>(_ method: String, path: String, query: [URLQueryItem] = [], body: Body?, idempotencyKey: String? = nil) async throws -> Response {
        let data = try await send(method, path: path, query: query, body: body, idempotencyKey: idempotencyKey)
        guard let result = try? decoder.decode(Response.self, from: data) else { throw InboxError.decoding }
        return result
    }

    private func perform<Body: Encodable>(_ method: String, path: String, query: [URLQueryItem] = [], body: Body?, idempotencyKey: String? = nil) async throws {
        _ = try await send(method, path: path, query: query, body: body, idempotencyKey: idempotencyKey)
    }

    private func send<Body: Encodable>(_ method: String, path: String, query: [URLQueryItem] = [], body: Body?, idempotencyKey: String? = nil) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw InboxError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = method
        try setIdentityHeaders(on: &request)
        if let body { request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        request.setValue("application/json, application/octet-stream, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw InboxError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw InboxError.unauthorized }
            let message = try? decoder.decode(ErrorResponse.self, from: data).message
            throw InboxError.httpStatus(response.statusCode, message)
        }
        return data
    }

    private func sendMultipart(path: String, fields: [(String, String)], attachments: [InboxAttachmentUpload], idempotencyKey: String) async throws -> Data {
        let allowedTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "application/pdf", "text/plain"]
        guard attachments.count <= 10,
              attachments.allSatisfy({ allowedTypes.contains($0.contentType.lowercased()) && $0.data.count <= 10 * 1_024 * 1_024 }),
              attachments.reduce(0, { $0 + $1.data.count }) <= 25 * 1_024 * 1_024 else {
            throw InboxError.invalidInput("Attachments must be up to 10 files, 10 MiB each, and 25 MiB total. Supported types are JPEG, PNG, GIF, WebP, PDF, and plain text.")
        }
        let boundary = "ReplyKit-\(UUID().uuidString)"
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        for attachment in attachments {
            let filename = URL(fileURLWithPath: attachment.filename).lastPathComponent
                .replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"\(filename)\"\r\nContent-Type: \(attachment.contentType.lowercased())\r\n\r\n")
            data.append(attachment.data); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        let components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        guard let url = components?.url else { throw InboxError.invalidResponse }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = data
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        try setIdentityHeaders(on: &request)
        let (responseData, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw InboxError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw InboxError.unauthorized }
            let message = try? decoder.decode(ErrorResponse.self, from: responseData).message
            throw InboxError.httpStatus(response.statusCode, message)
        }
        return responseData
    }

    private func setIdentityHeaders(on request: inout URLRequest) throws {
        request.setValue(configuration.appKey, forHTTPHeaderField: "X-ReplyKit-App-Key")
        request.setValue(try configuration.customerID().uuidString.lowercased(), forHTTPHeaderField: "X-ReplyKit-Customer-ID")
    }

    private struct CreateConversationBody: Encodable { let subject: String; let body: String }
    private struct SendMessageBody: Encodable { let body: String }
    private struct UnreadCountResponse: Decodable { let unreadCount: Int }
    private struct ErrorResponse: Decodable { let message: String? }
}
