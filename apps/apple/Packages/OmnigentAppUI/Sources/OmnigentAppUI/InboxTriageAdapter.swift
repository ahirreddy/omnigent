import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Inbox opens request streams without taking over the user's visible conversation.
struct InboxTriageAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  /// Shows a comment's file in its session's right panel: path, character offset, session.
  var openFile: ((String, UInt64?, String) -> Void)?
  @State private var ownedSessions: Set<String> = []
  @State private var readRevisions: [String: Double] = [:]
  @State private var banner: TransientBanner?

  private var readKey: String {
    "omnigent.inbox.read.\(connection.connectedServer?.baseUrl ?? "").\(connection.connectedServer?.userId ?? "")"
  }

  private var seenCommentsKey: String {
    "omnigent.inbox.seenComments.\(connection.connectedServer?.baseUrl ?? "").\(connection.connectedServer?.userId ?? "")"
  }

  /// Sessions with comments and their counts: a change reads their comments again.
  private var commentSignature: [String] {
    connection.sessionList.sessionsByID.values.filter { $0.commentsCount > 0 }
      .map { "\($0.id):\($0.commentsCount)" }.sorted()
  }

  /// Unread sessions and their activity: a change reads their latest output again.
  private var unreadSignature: [String] {
    unreadSessions.map { "\($0.id):\($0.updatedAt)" }.sorted()
  }

  private var unreadSessions: [OmnigentCoreFFI.SessionSummary] {
    connection.sessionList.unreadIDs.compactMap { connection.sessionList.session($0) }
      .filter { !$0.isArchived && $0.status != .needsResponse }
  }

  /// Activity of sessions with a sent reply, to settle the reply once the agent answers.
  private var replySignature: [String] {
    guard let replies = connection.pages?.replies, !replies.isEmpty else { return [] }
    return replies.keys.sorted().map { id in
      let session = connection.sessionList.session(id)
      return "\(id):\(session?.updatedAt ?? 0):\(String(describing: session?.status))"
    }
  }

  var body: some View {
    InboxView(
      state: InboxTriageMapping.state(connection: connection, readRevisions: readRevisions),
      actions: actions
    )
    .transientBanner($banner)
    .onAppear {
      readRevisions = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Double] ?? [:]
      connection.pages?.bindSeenComments(key: seenCommentsKey)
    }
    .task(id: commentSignature) {
      await connection.pages?.refreshComments(Array(connection.sessionList.sessionsByID.values))
    }
    .task(id: unreadSignature) {
      await connection.pages?.refreshLatestOutputs(unreadSessions)
    }
    .onChange(of: replySignature) {
      connection.pages?.settleReplies(connection.sessionList.sessionsByID)
    }
    .onChange(of: connection.sessionList.needsResponse.map(\.id), initial: true) { _, ids in
      for id in ids where connection.conversations[id] == nil {
        if connection.conversation(id) != nil { ownedSessions.insert(id) }
      }
    }
    .onDisappear {
      for id in ownedSessions { connection.closeConversation(id) }
      ownedSessions = []
    }
  }

  private var actions: InboxActions {
    let pages = connection.pages
    var actions = InboxActions(
      open: { item in
        ownedSessions.remove(item.sessionId)
        if let id = InboxTriageMapping.commentID(item) {
          pages?.markCommentSeen(id)
          if let comment = pages?.comments[item.sessionId]?.first(where: { $0.id == id }) {
            openFile?(comment.path, comment.startIndex, item.sessionId)
          }
        }
        pages?.clearReply(item.sessionId)
        open(item.sessionId)
      },
      markRead: { item in markRead(item) },
      reply: { item, text in
        guard let pages, let session = connection.sessionList.session(item.sessionId) else {
          return
        }
        Task {
          if await pages.reply(text, to: session) {
            banner = TransientBanner(message: "Reply sent to \(session.title)")
          }
        }
      },
      respond: { card, response in resolve(card, response) })
    actions.editReply = { item in pages?.clearReply(item.sessionId) }
    actions.retry = {
      Task {
        await pages?.refreshComments(Array(connection.sessionList.sessionsByID.values))
        await pages?.refreshLatestOutputs(unreadSessions)
      }
    }
    return actions
  }

  /// Comments clear on this device; unread sessions are marked seen on the server, as opening
  /// them does; other items keep a local read mark.
  private func markRead(_ item: InboxItem) {
    if let comment = InboxTriageMapping.commentID(item) {
      connection.pages?.markCommentSeen(comment)
    } else if item.kind == .unread {
      connection.pages?.clearReply(item.sessionId)
      Task { await connection.markSeen(item.sessionId) }
    } else {
      readRevisions[item.id] = item.date.timeIntervalSince1970
      UserDefaults.standard.set(readRevisions, forKey: readKey)
    }
  }

  private func resolve(
    _ card: OmnigentUIComponents.DecisionCard, _ response: OmnigentUIComponents.DecisionResponse
  ) {
    guard let conversation = connection.conversations[card.carryingSessionId],
      let original = conversation.decisions.pending.first(where: { $0.id == card.id }),
      conversation.header?.readOnly != true,
      !conversation.decisions.resolving.contains(card.id)
    else { return }
    Task {
      await conversation.decisions.resolve(
        original, with: OmnigentCoreFFI.DecisionResponse(response))
    }
  }
}
