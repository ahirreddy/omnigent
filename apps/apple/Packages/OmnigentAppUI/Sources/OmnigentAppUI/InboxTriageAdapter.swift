import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Inbox opens request streams without taking over the user's visible conversation.
struct InboxTriageAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  @State private var ownedSessions: Set<String> = []
  @State private var readRevisions: [String: Double] = [:]

  private var readKey: String {
    "omnigent.inbox.read.\(connection.connectedServer?.baseUrl ?? "").\(connection.connectedServer?.userId ?? "")"
  }

  var body: some View {
    InboxView(
      state: InboxTriageMapping.state(connection: connection, readRevisions: readRevisions),
      actions: InboxActions(
        open: { item in
          ownedSessions.remove(item.sessionId)
          open(item.sessionId)
        },
        markRead: { item in
          readRevisions[item.id] = item.date.timeIntervalSince1970
          UserDefaults.standard.set(readRevisions, forKey: readKey)
        },
        respond: { card, response in resolve(card, response) })
    )
    .onAppear {
      readRevisions = UserDefaults.standard.dictionary(forKey: readKey) as? [String: Double] ?? [:]
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

/// Maps already-decoded core records; the stores remain responsible for resolving requests.
enum InboxTriageMapping {
  static func state(connection: ConnectionStore, readRevisions: [String: Double]) -> InboxViewState
  {
    let unread = Set(connection.notifications?.badgeSessionIDs ?? [])
    let sessions = connection.sessionList.sessionsByID.values.sorted {
      $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
    }
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
        var item = item(target, serverName: connection.connectedServer?.serverName, unread: unread)
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
      if cards.isEmpty,
        summary.status == .needsResponse || unread.contains(summary.id) || summary.isPinned
      {
        var item = item(summary, serverName: connection.connectedServer?.serverName, unread: unread)
        if let failure = conversation?.errors.last { item.preview = failure.message }
        items.append(item)
      }
    }
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
    var state = InboxViewState(items: items)
    // Sessions, not requests: the header matches the sidebar, Dock and menu bar.
    state.needsYouCount = Int(connection.sessionList.attentionTotals.sessionsNeedingYou)
    return state
  }

  static func summaryText(_ card: OmnigentUIComponents.DecisionCard) -> String {
    if let command = card.permissions.command { return command.command }
    if case .form(let fields) = card.kind {
      return ([card.detail] + fields.map(\.title)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    return card.detail.isEmpty ? card.title : card.detail
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
