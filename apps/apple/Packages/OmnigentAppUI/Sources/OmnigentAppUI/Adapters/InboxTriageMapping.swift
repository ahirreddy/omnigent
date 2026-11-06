import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps already-decoded core records; the stores remain responsible for resolving requests.
enum InboxTriageMapping {
  private static let commentPrefix = "comment-"

  static func state(connection: ConnectionStore, readRevisions: [String: Double]) -> InboxViewState
  {
    let unread = Set(connection.notifications?.badgeSessionIDs ?? [])
    let sessions = connection.sessionList.sessionsByID.values.sorted {
      $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
    }
    let serverName = connection.connectedServer?.serverName
    var items: [InboxItem] = []
    var seenRequests: Set<String> = []
    for summary in sessions {
      let conversation = connection.conversations[summary.id]
      let cards =
        conversation?.decisions.cards.filter {
          !$0.answered || conversation?.decisions.resolving.contains($0.id) == true
            || conversation?.decisions.errors[$0.id] != nil
        } ?? []
      for card in cards {
        let identity = "\(card.targetSessionId):\(card.id)"
        guard seenRequests.insert(identity).inserted else { continue }
        let target = connection.sessionList.session(card.targetSessionId) ?? summary
        var item = item(target, serverName: serverName, unread: unread)
        item.id = "request-\(identity)"
        let decision = OmnigentUIComponents.DecisionCard(card)
        item.decision = decision
        item.kind = decision.kind == .approval ? .approval : .question
        item.preview = summaryText(decision)
        item.phase = phase(card, store: conversation?.decisions)
        if case .resolving = item.phase { item.decision?.answered = false }
        item.isReadOnly = conversation?.header?.readOnly ?? summary.isReadOnly
        items.append(item)
      }
      if cards.isEmpty, let item = sessionItem(summary, connection: connection, unread: unread) {
        items.append(item)
      }
    }
    items += comments(connection)
    for index in items.indices {
      let item = items[index]
      if let hostID = connection.sessionList.session(item.sessionId)?.configuration?.hostId {
        let host = connection.creationStore?.catalog.value?.hosts.first { $0.hostId == hostID }
        items[index].executionContext += " · \(host?.name ?? "Host \(hostID)")"
      }
      if let read = readRevisions[item.id], read >= item.date.timeIntervalSince1970 {
        items[index].isUnread = false
      }
    }
    return viewState(items, connection: connection)
  }

  /// The items with the header's counts and the list's loading and paging.
  private static func viewState(_ items: [InboxItem], connection: ConnectionStore)
    -> InboxViewState
  {
    var state = InboxViewState(items: items)
    // Sessions, not requests: the header matches the sidebar, Dock and menu bar.
    state.needsYouCount = Int(connection.sessionList.attentionTotals.sessionsNeedingYou)
    state.failedSessionCount =
      (connection.pages?.commentErrors.count ?? 0) + (connection.pages?.outputErrors.count ?? 0)
    state.isAssembling = isAssembling(connection)
    state.hasMoreSessions = connection.sessionList.paging.hasMore
    state.isLoadingMoreSessions = connection.sessionList.paging.isLoading
    return state
  }

  /// The list, a waiting session's requests, comments or replies are still being read.
  static func isAssembling(_ connection: ConnectionStore) -> Bool {
    if !connection.sessionList.isLoaded || connection.pages?.isReadingInbox == true { return true }
    return connection.sessionList.needsResponse.contains { summary in
      guard let conversation = connection.conversations[summary.id] else { return false }
      return !conversation.isHydrated && conversation.errors.isEmpty
    }
  }

  /// A session without a loaded request: waiting on the user, or with unseen output (the
  /// sidebar's unread dot), which can be answered in place. As the web, pinning alone does not
  /// list a session.
  private static func sessionItem(
    _ summary: OmnigentCoreFFI.SessionSummary, connection: ConnectionStore, unread: Set<String>
  ) -> InboxItem? {
    let reply = connection.pages?.replies[summary.id]
    let unseen = connection.sessionList.unreadIDs.contains(summary.id) && !summary.isArchived
    guard
      summary.status == .needsResponse || unread.contains(summary.id) || unseen || reply != nil
    else { return nil }
    var item = item(
      summary, serverName: connection.connectedServer?.serverName, unread: unread)
    if let failure = connection.conversations[summary.id]?.errors.last {
      item.preview = failure.message
    }
    if summary.status != .needsResponse {
      if let output = connection.pages?.latestOutputs[summary.id] {
        item.preview = output.preview
        item.fullText = output.fullText
      }
      item.isUnread = item.isUnread || unseen || reply != nil
      item.isError = summary.failureMessage != nil
      if let failure = summary.failureMessage, item.preview == "Failed" { item.preview = failure }
      // The server refuses user messages below edit access.
      item.canReply = !summary.isReadOnly && !summary.isArchived
      item.reply = phase(reply)
    }
    return item
  }

  /// Open comments other people left that this device has not seen.
  private static func comments(_ connection: ConnectionStore) -> [InboxItem] {
    guard let pages = connection.pages else { return [] }
    return pages.unseenComments(viewerID: connection.sessionList.viewerID).compactMap { comment in
      guard let session = connection.sessionList.session(comment.sessionId), !session.isArchived
      else { return nil }
      let author = comment.author ?? "Someone"
      var item = InboxItem(
        id: commentPrefix + comment.id, kind: .comment, sessionId: comment.sessionId,
        sessionTitle: session.title, preview: "\(author): \(comment.body)",
        date: Date(timeIntervalSince1970: TimeInterval(comment.createdAt)))
      item.comment = InboxComment(
        author: author, path: comment.path, anchor: comment.anchor, body: comment.body)
      item.agentName = session.agentName
      return item
    }
  }

  /// The comment an item shows, if it is one.
  static func commentID(_ item: InboxItem) -> String? {
    guard item.kind == .comment, item.id.hasPrefix(commentPrefix) else { return nil }
    return String(item.id.dropFirst(commentPrefix.count))
  }

  static func summaryText(_ card: OmnigentUIComponents.DecisionCard) -> String {
    if let command = card.permissions.command { return command.command }
    if case .form(let fields) = card.kind {
      return ([card.detail] + fields.map(\.title)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    return card.detail.isEmpty ? card.title : card.detail
  }

  private static func phase(_ reply: ReplyState?) -> InboxReplyPhase {
    switch reply {
    case nil: .idle
    case .sending: .sending
    case .sent: .sent
    case .failed(let error): .failed(message: error.message)
    }
  }

  private static func item(
    _ summary: OmnigentCoreFFI.SessionSummary, serverName: String?, unread: Set<String>
  ) -> InboxItem {
    var item = InboxItem(
      id: "session-\(summary.id)", kind: summary.status == .needsResponse ? .approval : .unread,
      sessionId: summary.id, sessionTitle: summary.title, preview: summary.preview,
      date: Date(timeIntervalSince1970: TimeInterval(summary.updatedAt)),
      isUnread: unread.contains(summary.id))
    item.agentName = summary.agentName
    item.executionContext = [serverName ?? "Connected server", summary.workspace]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    item.isPinned = summary.isPinned
    item.isReadOnly = summary.isReadOnly
    return item
  }

  private static func phase(_ card: OmnigentCoreFFI.DecisionCard, store: DecisionStore?)
    -> DecisionPhase
  {
    if let failure = store?.errors[card.id] { return .failed(message: failure.message) }
    if store?.resolving.contains(card.id) == true { return .resolving }
    return card.answered ? .answered(summary: "Answered") : .pending
  }
}
