import SwiftUI

public struct ReplyKitView: View {
    @ObservedObject private var store: ReplyKitStore
    private let theme: InboxTheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingComposer = false

    public init(store: ReplyKitStore, theme: InboxTheme = InboxTheme()) { self.store = store; self.theme = theme }

    public var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.conversations.isEmpty { ProgressView("Loading inbox…") }
                else if store.conversations.isEmpty { emptyState }
                else { conversationList }
            }
            .navigationTitle(theme.inboxTitle)
            .toolbar {
                ToolbarItem(placement: trailingPlacement) {
                    Button { showingComposer = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New message")
                }
                ToolbarItem(placement: .principal) {
                    if store.unreadCount > 0 { Text("\(store.unreadCount) unread").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .tint(theme.tint.swiftUIColor)
            .refreshable { await store.refresh() }
            .task { store.setForeground(scenePhase == .active) }
            .modifier(CompatibleOnChange(value: scenePhase) { phase in store.setForeground(phase == .active) })
            .sheet(isPresented: $showingComposer) {
                NavigationStack { NewMessageView(store: store, theme: theme) { showingComposer = false } }
            }
            .alert("Inbox", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.clearError() } })) {
                Button("Retry") { Task { await store.refresh() } }
                Button("Dismiss", role: .cancel) { store.clearError() }
            } message: { Text(store.errorMessage ?? "Something went wrong.") }
        }
    }

    private var trailingPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .navigationBarTrailing
        #else
        .primaryAction
        #endif
    }

    private var conversationList: some View {
        List {
            ForEach(store.conversations) { conversation in
                NavigationLink {
                    ConversationView(store: store, conversation: conversation, theme: theme)
                } label: { ConversationRow(conversation: conversation) }
            }
            if store.hasMoreConversations {
                Button { Task { await store.loadMoreConversations() } } label: {
                    HStack { Spacer(); if store.isLoadingMoreConversations { ProgressView() } else { Text("Load more conversations") }; Spacer() }
                }.disabled(store.isLoadingMoreConversations)
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
            Text(theme.emptyTitle).font(.title3.weight(.semibold))
            Text("Send a message to start a conversation with support.").foregroundStyle(.secondary)
            Button("New message") { showingComposer = true }.buttonStyle(.borderedProminent)
            if let error = store.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Retry") { Task { await store.refresh() } }
            }
        }.padding()
    }
}

extension ColorToken {
    var swiftUIColor: Color {
        switch self {
        case .blue: .blue; case .indigo: .indigo; case .teal: .teal; case .green: .green
        case .orange: .orange; case .purple: .purple; case .red: .red
        }
    }
}
