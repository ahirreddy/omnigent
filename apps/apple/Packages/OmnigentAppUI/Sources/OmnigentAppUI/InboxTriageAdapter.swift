import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Inbox opens request streams without taking over the user's visible conversation.
struct InboxTriageAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  /// Opens New session with a draft: an agent-posted item's action.
  var startSession: ((String) -> Void)?
  /// Opens an automation's page.
  var openAutomation: ((String) -> Void)?
  /// Opens a web page.
  var openURL: ((URL) -> Void)?
  /// Shows a comment's file in its session's right panel: path, character offset, session.
  var openFile: ((String, UInt64?, String) -> Void)?
  /// Where this device's read marks live.
  var defaults = UserDefaults.standard
  @State private var ownedSessions: Set<String> = []
  @State private var readRevisions: [String: Double] = [:]
  @State private var banner: TransientBanner?

  private var readKey: String {
    "omnigent.inbox.read.\(connection.connectedServer?.baseUrl ?? "").\(connection.connectedServer?.userId ?? "")"
  }

  var seenCommentsKey: String { InboxFeedsPolling.seenCommentsKey(connection) }

  /// The feeds the server offers: a change reads them again.
  private var feedsSignature: [Bool] {
    let offered = connection.pages?.offered
    return [
      offered?.inboxItems == true, offered?.automationInbox == true, offered?.advisor == true,
    ]
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
      readRevisions = defaults.dictionary(forKey: readKey) as? [String: Double] ?? [:]
      connection.pages?.bindSeenComments(key: seenCommentsKey)
      connection.pages?.feeds.bindReadFailures(key: InboxFeedsPolling.readFailuresKey(connection))
    }
    // As the web, opening the Inbox reads its feeds again.
    .task(id: feedsSignature) { await connection.pages?.refreshInboxFeeds() }
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

  var actions: InboxActions {
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
    actions.validateForm = { card, values in
      let pending = connection.conversations[card.carryingSessionId]?.decisions.pending ?? []
      return .fromCore(cards: pending, cardID: card.id, values: values)
    }
    actions.editReply = { item in pages?.clearReply(item.sessionId) }
    actions.retry = {
      Task {
        await pages?.refreshComments(Array(connection.sessionList.sessionsByID.values))
        await pages?.refreshLatestOutputs(unreadSessions)
      }
    }
    let paging = connection.sessionList.paging
    actions.loadMoreSessions = { paging.loadMore() }
    feedActions(&actions)
    return actions
  }

  /// Agent-posted items and automation failures.
  private func feedActions(_ actions: inout InboxActions) {
    guard let feeds = connection.pages?.feeds else { return }
    actions.takeSuggestionAction = { item, index in
      guard let id = InboxFeedsMapping.suggestionID(item),
        let record = feeds.items.first(where: { $0.id == id }), index < record.actions.count
      else { return }
      // As the web, the draft opens at once; the server records the action alongside.
      Task { await feeds.takeAction(id, index: UInt32(index)) }
      startSession?(record.actions[index].prompt)
    }
    actions.dismissSuggestion = { item, choice in
      guard let id = InboxFeedsMapping.suggestionID(item),
        let reason = InboxFeedsMapping.reason(choice)
      else { return }
      Task { await feeds.dismiss(id, reason: reason) }
    }
    actions.openLink = { link in
      if let sessionID = link.sessionID {
        open(sessionID)
      } else if let url = link.url {
        openURL?(url)
      }
    }
    actions.openSource = { item in open(item.sessionId) }
    if let openAutomation {
      actions.openAutomation = { item in
        if let id = item.automationFailure?.automationID { openAutomation(id) }
      }
    }
    actions.retrySuggestions = { Task { await feeds.refreshItems() } }
    actions.loadMoreSuggestions = { Task { await feeds.loadMoreItems() } }
    actions.retryAutomations = { Task { await feeds.refreshFailures() } }
    actions.retryAdvisorSettings = { Task { await feeds.advisor.loadSettings() } }
    actions.loadMoreAutomations = { Task { await feeds.loadMoreFailures() } }
  }

  /// Comments clear on this device; unread sessions are marked seen on the server, as opening
  /// them does; other items keep a local read mark.
  private func markRead(_ item: InboxItem) {
    if let comment = InboxTriageMapping.commentID(item) {
      connection.pages?.markCommentSeen(comment)
    } else if let id = InboxFeedsMapping.suggestionID(item) {
      Task { await connection.pages?.feeds.markRead(id) }
    } else if let run = InboxFeedsMapping.runID(item) {
      connection.pages?.feeds.markFailureRead(run)
    } else if item.kind == .unread {
      connection.pages?.clearReply(item.sessionId)
      Task { await connection.markSeen(item.sessionId) }
    } else {
      readRevisions[item.id] = item.date.timeIntervalSince1970
      defaults.set(readRevisions, forKey: readKey)
    }
  }

  private func resolve(
    _ card: OmnigentUIComponents.DecisionCard, _ response: OmnigentUIComponents.DecisionResponse
  ) {
    guard let conversation = connection.conversations[card.carryingSessionId],
      let original = conversation.decisions.pending.first(where: { $0.id == card.id }),
      conversation.header?.readOnly != true
    else { return }
    Task {
      await conversation.decisions.resolve(
        original, with: OmnigentCoreFFI.DecisionResponse(response))
    }
  }
}
