import SwiftUI
import UniformTypeIdentifiers
import QuickLook
#if os(macOS)
import AppKit
#endif

struct ConversationRow: View {
    let conversation: InboxConversation
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3).foregroundStyle(.tint).frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.subject).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(conversation.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                Text(conversation.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if conversation.unreadCount > 0 {
                Circle().fill(Color.accentColor).frame(width: 9, height: 9).accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

public struct ConversationView: View {
    @ObservedObject private var store: ReplyKitStore
    let conversation: InboxConversation
    let theme: InboxTheme
    @FocusState private var replyFocused: Bool
    @State private var failedOperation: FailedOperation = .loadMessages
    @State private var previewURL: URL?
    @State private var attachmentError: String?
    private enum FailedOperation { case loadMessages, loadOlder(anchorID: String?), reply }

    public init(store: ReplyKitStore, conversation: InboxConversation, theme: InboxTheme = InboxTheme()) {
        self.store = store; self.conversation = conversation; self.theme = theme
    }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if let error = store.errorMessage {
                VStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Text("Check your connection and retry the last action.").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { Task { await retry(using: proxy) } }
                }.padding()
                }
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if store.isLoadingMessages(for: conversation.id) && (store.messagesByConversation[conversation.id]?.isEmpty ?? true) {
                            ProgressView("Loading messages…")
                        } else if store.messagesByConversation[conversation.id]?.isEmpty ?? true, store.errorMessage == nil {
                            Text("No messages in this conversation yet.").foregroundStyle(.secondary).padding()
                        }
                        if store.hasMoreMessages(for: conversation.id) {
                            Button("Load older messages") { Task { await loadOlder(using: proxy) } }
                                .font(.footnote).disabled(store.isLoadingMessages(for: conversation.id))
                        }
                        ForEach(store.messagesByConversation[conversation.id] ?? []) { message in
                            MessageBubble(message: message) { attachment in
                                Task {
                                    do { presentPreview(try await store.downloadAttachment(attachment)); attachmentError = nil }
                                    catch { attachmentError = error.localizedDescription }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                }
                
                .task {
                    failedOperation = .loadMessages
                    await store.loadMessages(for: conversation.id)
                    if store.errorMessage == nil { withAnimation { proxy.scrollTo("bottom") } }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Write a reply…", text: replyBinding, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.roundedBorder).focused($replyFocused)
                        .accessibilityLabel("Reply message")
                    Button { Task {
                        failedOperation = .reply
                        await store.sendReply(to: conversation.id)
                        if store.errorMessage == nil { withAnimation { proxy.scrollTo("bottom") } }
                    } } label: {
                        if store.isSubmitting { ProgressView() } else { Image(systemName: "paperplane.fill") }
                    }
                    .buttonStyle(.borderedProminent).disabled(store.isSubmitting || (replyBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (store.replyAttachments[conversation.id] ?? []).isEmpty))
                    .accessibilityLabel("Send reply")
                }.padding()
                AttachmentComposer(attachments: replyAttachmentBinding, isDisabled: store.isSubmitting)
                    .padding(.horizontal).padding(.bottom, 8)
            }
        }
        .modifier(AttachmentPreview(url: $previewURL))
        .alert("Attachment unavailable", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("OK", role: .cancel) { attachmentError = nil }
        } message: { Text(attachmentError ?? "") }
        .navigationTitle(conversation.subject).modifier(InlineNavigationTitle()).tint(theme.tint.swiftUIColor)
    }

    private func loadOlder(using proxy: ScrollViewProxy) async {
        let anchorID = store.messagesByConversation[conversation.id]?.first?.id
        failedOperation = .loadOlder(anchorID: anchorID)
        await store.loadMessages(for: conversation.id, loadMore: true)
        if store.errorMessage == nil, let anchorID {
            withAnimation { proxy.scrollTo(anchorID, anchor: .top) }
        }
    }

    private func retry(using proxy: ScrollViewProxy) async {
        switch failedOperation {
        case .loadMessages:
            await store.loadMessages(for: conversation.id)
            if store.errorMessage == nil { withAnimation { proxy.scrollTo("bottom") } }
        case .loadOlder(let anchorID):
            await store.loadMessages(for: conversation.id, loadMore: true)
            if store.errorMessage == nil, let anchorID { withAnimation { proxy.scrollTo(anchorID, anchor: .top) } }
        case .reply:
            await store.sendReply(to: conversation.id)
            if store.errorMessage == nil { withAnimation { proxy.scrollTo("bottom") } }
        }
    }

    private var replyBinding: Binding<String> {
        Binding(get: { store.replyDrafts[conversation.id] ?? "" }, set: { store.replyDrafts[conversation.id] = $0 })
    }
    private var replyAttachmentBinding: Binding<[InboxAttachmentUpload]> {
        Binding(get: { store.replyAttachments[conversation.id] ?? [] }, set: { store.replyAttachments[conversation.id] = $0 })
    }

    private func presentPreview(_ url: URL) {
        #if os(iOS)
        previewURL = url
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

private struct MessageBubble: View {
    let message: InboxMessage
    let openAttachment: (InboxAttachment) -> Void
    var body: some View {
        HStack {
            if message.isFromSupport { bubble; Spacer(minLength: 30) }
            else { Spacer(minLength: 30); bubble }
        }
        .accessibilityElement(children: .combine)
    }
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.sender).font(.caption.weight(.semibold))
                Spacer()
                Text(message.sentAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(message.body).textSelection(.enabled)
            ForEach(message.attachments) { attachment in
                Button { openAttachment(attachment) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: attachment.contentType.hasPrefix("image/") ? "photo" : "doc")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.filename).lineLimit(1)
                            Text("\(attachment.size.formatted(.byteCount(style: .file))) · \(attachment.senderLabel)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4); Image(systemName: "arrow.down.circle")
                    }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("Open attachment \(attachment.filename), sent by \(attachment.senderLabel)")
            }
        }
        .padding(12).background(message.isFromSupport ? Color.secondary.opacity(0.12) : Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(message.isFromSupport ? Color.primary : Color.white)
    }
}

public struct NewMessageView: View {
    @ObservedObject private var store: ReplyKitStore
    let theme: InboxTheme
    let onSubmitted: () -> Void
    @FocusState private var focusedField: Field?
    private enum Field { case subject, body }

    public init(store: ReplyKitStore, theme: InboxTheme = InboxTheme(), onSubmitted: @escaping () -> Void = {}) {
        self.store = store; self.theme = theme; self.onSubmitted = onSubmitted
    }

    public var body: some View {
        Form {
        Section("Message") {
                TextField("Subject", text: $store.newConversationDraft.subject)
                    .modifier(SentenceCapitalization()).focused($focusedField, equals: .subject)
                    .accessibilityLabel("Subject")
                TextField("How can we help?", text: $store.newConversationDraft.body, axis: .vertical)
                    .lineLimit(6...12).focused($focusedField, equals: .body)
                    .accessibilityLabel("Message")
            }
            Section {
                Text("Replies appear in your inbox. You won’t need to share your email address here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        AttachmentComposer(attachments: $store.newConversationDraft.attachments, isDisabled: store.isSubmitting)
        .navigationTitle(theme.newMessageTitle).modifier(InlineNavigationTitle()).tint(theme.tint.swiftUIColor)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onSubmitted) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { Task { await store.submitNewConversation(); if store.newConversationDraft.subject.isEmpty && store.newConversationDraft.body.isEmpty { onSubmitted() } } }
                    .disabled(store.isSubmitting || !isValid)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.errorMessage {
                HStack { Text(error).font(.footnote); Spacer(); Button("Retry") { Task { await store.submitNewConversation() } } }
                    .padding().background(.regularMaterial).accessibilityLabel("Submission error: \(error)")
            }
        }
    }
    private var isValid: Bool {
        !store.newConversationDraft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !store.newConversationDraft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension InboxAttachment {
    var senderLabel: String {
        switch senderType?.lowercased() {
        case "customer": "You"
        case "admin": "Support"
        default: "Attachment"
        }
    }
}

private struct AttachmentComposer: View {
    @Binding var attachments: [InboxAttachmentUpload]
    let isDisabled: Bool
    @State private var isImporting = false
    @State private var errorMessage: String?
    private let maxFileSize = 10 * 1_024 * 1_024
    private let maxRequestSize = 25 * 1_024 * 1_024
    private let allowedMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "application/pdf", "text/plain"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isImporting = true } label: {
                Label("Add attachment", systemImage: "paperclip")
            }.disabled(isDisabled || attachments.count >= 10)
            ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                HStack {
                    Image(systemName: "doc"); Text(attachment.filename).lineLimit(1)
                    Text(attachment.data.count.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { attachments.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                        .disabled(isDisabled).accessibilityLabel("Remove \(attachment.filename)")
                }.font(.footnote)
            }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.allowedContentTypes, allowsMultipleSelection: true, onCompletion: importFiles)
    }

    private static var allowedContentTypes: [UTType] {
        [.jpeg, .png, .gif, .pdf, .plainText] + [UTType(filenameExtension: "webp")].compactMap { $0 }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            for url in urls {
                guard attachments.count < 10 else { throw InboxError.invalidInput("You can attach up to 10 files.") }
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                let mime = values.contentType?.preferredMIMEType?.lowercased() ?? ""
                guard allowedMIMETypes.contains(mime) else { throw InboxError.invalidInput("Choose a JPEG, PNG, GIF, WebP, PDF, or plain text file.") }
                guard let fileSize = values.fileSize, fileSize <= maxFileSize else { throw InboxError.invalidInput("Each attachment must be 10 MiB or smaller.") }
                guard attachments.reduce(0, { $0 + $1.data.count }) + fileSize <= maxRequestSize else { throw InboxError.invalidInput("Attachments must total 25 MiB or less.") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                attachments.append(InboxAttachmentUpload(filename: url.lastPathComponent, contentType: mime, data: data))
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AttachmentPreview: ViewModifier {
    @Binding var url: URL?
    func body(content: Content) -> some View {
        #if os(iOS)
        content.quickLookPreview($url)
        #else
        content
        #endif
    }
}

private struct InlineNavigationTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

private struct SentenceCapitalization: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.textInputAutocapitalization(.sentences)
        #else
        content
        #endif
    }
}

struct CompatibleOnChange<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onChange(of: value) { _, newValue in action(newValue) }
        #else
        if #available(iOS 17, *) {
            content.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            content.onChange(of: value) { newValue in action(newValue) }
        }
        #endif
    }
}
