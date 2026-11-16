import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

// A session's sub-agents and forked side chats show in tabs of that session's strip, beside its
// chat, as the web shows them in the parent's panel. They never take the window as a session.

/// A session the stream reported under another, as its row shows it.
nonisolated struct ListedChild: Hashable, Sendable {
  let id: String
  let name: String
  /// A side chat the session's agent forked, rather than a sub-agent.
  let isSideChat: Bool
}

extension ConversationStore {
  /// The sessions the stream reported under this one (sub-agents, an agent's own side-chat
  /// forks), in the order they started.
  var listedChildren: [ListedChild] {
    sections.compactMap { section in
      guard section.id.hasPrefix("child-"), let id = section.sessionId else { return nil }
      let isSideChat = section.details.contains { $0.id == "kind" && $0.text == "side_chat" }
      return ListedChild(id: id, name: section.title, isSideChat: isSideChat)
    }
  }
}

/// What a group's open conversations know of the sessions under them: each one's parent, the
/// name it is listed under and which are side chats (the stream's child rows, the Agents tab's
/// tree).
struct KnownChildren {
  private(set) var parents: [String: String] = [:]
  private(set) var names: [String: String] = [:]
  private(set) var sideChats: Set<String> = []

  init(_ conversations: [ConversationStore]) {
    for conversation in conversations {
      for child in conversation.listedChildren {
        parents[child.id] = conversation.sessionID
        names[child.id] = child.name
        if child.isSideChat { sideChats.insert(child.id) }
      }
      for node in conversation.tools.agentTree?.nodes ?? [] {
        if let parentID = node.parentId { parents[node.sessionId] = parentID }
        names[node.sessionId] = node.name
        if node.isSideChat { sideChats.insert(node.sessionId) }
      }
    }
  }

  /// Whether `sessionID` runs under `ancestorID`, however deep; `listedParent` is asked for a
  /// link the conversations did not report.
  func runs(
    _ sessionID: String, under ancestorID: String, listedParent: (String) -> String?
  ) -> Bool {
    var current = sessionID
    // A bound on the walk, so a parent link that loops ends it.
    for _ in 0..<32 {
      guard let parent = parents[current] ?? listedParent(current) else { return false }
      if parent == ancestorID { return true }
      current = parent
    }
    return false
  }
}

/// The side chats asked of a session's own agent that it has not reported yet (web
/// `awaitingSideChatFor` and `awaitingPendingIdsRef`). A fork is reported as a new child with
/// nothing to pair it on, so each wait takes the next child the session did not have when it
/// was queued, oldest wait first. A wait not answered within ``patience`` is late: it waits on,
/// but takes only a child the core marks as a side chat, so a late fork still opens and a
/// sub-agent the agent starts meanwhile is never taken for it.
final class ForkedSideChats {
  typealias WaitID = UUID
  /// Withdraws a wait whose request was not sent.
  typealias Withdraw = @MainActor () -> Void

  private struct Wait {
    let id: WaitID
    /// The children the session had when the wait was queued.
    let before: Set<String>
    let forked: @MainActor (String) -> Void
    let late: @MainActor () -> Void
    let gaveUp: @MainActor () -> Void
    let timeout: Task<Void, Never>
    var isLate = false

    func takes(_ child: ListedChild) -> Bool {
      !before.contains(child.id) && (!isLate || child.isSideChat)
    }
  }

  private struct Parent {
    /// The children paired with a wait.
    var paired: Set<String> = []
    var waits: [Wait] = []
    var watch: Task<Void, Never>?
  }

  private var parents: [String: Parent] = [:]
  /// How long a fork may take to be reported before its wait is late.
  var patience: Duration = .seconds(60)

  /// Queues a wait for the next new child of `conversation`. Call it before the request that
  /// asks for the fork, so waits pair in the order their requests went.
  /// - Parameters:
  ///   - conversation: The session whose agent forks.
  ///   - late: No fork was reported within ``patience``; the wait goes on.
  ///   - gaveUp: The session closed, so no fork can be seen.
  ///   - forked: The fork's session.
  /// - Returns: The wait, to ``cancel(_:of:)`` when the request is refused.
  @discardableResult
  func awaitFork(
    of conversation: ConversationStore, late: @escaping @MainActor () -> Void = {},
    gaveUp: @escaping @MainActor () -> Void, forked: @escaping @MainActor (String) -> Void
  ) -> WaitID {
    let parentID = conversation.sessionID
    let id = WaitID()
    let patience = patience
    let timeout = Task { [weak self] in
      do {
        try await Task.sleep(for: patience)
      } catch {
        // Paired or withdrawn meanwhile.
        return
      }
      self?.lapse(id, of: parentID)
    }
    var parent = parents[parentID] ?? Parent()
    parent.waits.append(
      Wait(
        id: id, before: Set(conversation.listedChildren.map(\.id)), forked: forked, late: late,
        gaveUp: gaveUp, timeout: timeout))
    if parent.watch == nil { parent.watch = watch(conversation) }
    parents[parentID] = parent
    return id
  }

  /// Withdraws a wait whose request was not sent: no fork comes for it.
  func cancel(_ id: WaitID, of parentID: String) {
    guard var parent = parents[parentID],
      let index = parent.waits.firstIndex(where: { $0.id == id })
    else { return }
    parent.waits.remove(at: index).timeout.cancel()
    keep(parent, for: parentID)
  }

  /// The session closed: its forks can no longer be seen, so every wait gives up.
  func sessionClosed(_ parentID: String) {
    guard let parent = parents.removeValue(forKey: parentID) else { return }
    parent.watch?.cancel()
    for wait in parent.waits {
      wait.timeout.cancel()
      wait.gaveUp()
    }
  }

  /// Whether a fork of `parentID` is awaited.
  func isAwaiting(_ parentID: String) -> Bool { parents[parentID] != nil }

  /// Whether the wait `id` for a fork of `parentID` is past its patience.
  func isLate(_ id: WaitID, of parentID: String) -> Bool {
    parents[parentID]?.waits.contains { $0.id == id && $0.isLate } == true
  }

  private func watch(_ conversation: ConversationStore) -> Task<Void, Never> {
    let parentID = conversation.sessionID
    return Task { [weak self] in
      // A child's side-chat mark can come after the child, so the marks are watched too.
      for await children in Observations({ conversation.listedChildren }) {
        guard !Task.isCancelled, let self else { return }
        pair(children, of: parentID)
      }
    }
  }

  /// Hands each child not paired yet to the oldest wait that takes it, in the order they
  /// started.
  private func pair(_ children: [ListedChild], of parentID: String) {
    guard var parent = parents[parentID] else { return }
    var paired: [(wait: Wait, childID: String)] = []
    for child in children where !parent.paired.contains(child.id) {
      guard let index = parent.waits.firstIndex(where: { $0.takes(child) }) else { continue }
      parent.paired.insert(child.id)
      paired.append((parent.waits.remove(at: index), child.id))
    }
    keep(parent, for: parentID)
    for (wait, childID) in paired {
      wait.timeout.cancel()
      wait.forked(childID)
    }
  }

  /// A wait's patience ran out: from now on it takes only a child marked as a side chat.
  private func lapse(_ id: WaitID, of parentID: String) {
    guard var parent = parents[parentID],
      let index = parent.waits.firstIndex(where: { $0.id == id })
    else { return }
    parent.waits[index].isLate = true
    parents[parentID] = parent
    parent.waits[index].late()
  }

  /// Stores the session's waits, or stops watching it once none are left.
  private func keep(_ parent: Parent, for parentID: String) {
    if parent.waits.isEmpty {
      parent.watch?.cancel()
      parents[parentID] = nil
    } else {
      parents[parentID] = parent
    }
  }
}

extension WindowTabs {
  /// Opens `content` in `ownerID`'s tabs, focusing a tab that already shows it, and shows that
  /// session: a side chat's or sub-agent's own tabs open beside it, in the strip it is in.
  func open(_ content: AppTabContent, in ownerID: String, title: String? = nil) {
    groups.group(ownerID).open(content, title: title)
    groups.show(.session(ownerID))
  }

  /// Opens a sub-agent or forked side chat that runs under `ownerID`: the tab already showing
  /// it, else a sub-agent's window of its own when `apart` is given, else a new tab in
  /// `ownerID`'s strip.
  /// - Parameters:
  ///   - childID: The child session.
  ///   - sourceID: The conversation that listed it, for its name and kind.
  ///   - ownerID: The session whose tabs it joins.
  ///   - apart: Opens a sub-agent in another window (Settings › Open sub-agents in a new
  ///     window).
  func openChild(
    _ childID: String, from sourceID: String, in ownerID: String,
    apart: (@MainActor (String) -> Void)? = nil
  ) {
    let known = knownChildren(of: ownerID, and: sourceID)
    let isSideChat = known.sideChats.contains(childID)
    let isShown = groups.group(ownerID).tabs.contains { $0.content.conversationID == childID }
    if let apart, !isSideChat, !isShown {
      apart(childID)
      return
    }
    groups.openChild(childID, in: ownerID, isSideChat: isSideChat, name: known.names[childID])
    groups.show(.session(ownerID))
  }

  /// Move Tab to New Window, for the sub-agent tab `id`: it leaves `store`'s strip without being
  /// remembered as closed, and its session opens in a window of its own; `nil` where the
  /// platform has no windows or another kind of tab is named.
  func moveToNewWindow(_ id: String, from store: TabStore) -> (@MainActor () -> Void)? {
    guard let openInNewWindow, let childID = store.tab(id)?.content.ownWindowSessionID else {
      return nil
    }
    return {
      if store.detach(id) != nil { openInNewWindow(childID) }
    }
  }

  /// Opens a session that `sourceID`'s conversation links to, from a tab of `ownerID`: one that
  /// runs under `ownerID` joins its tabs (`openChild`), `ownerID` itself shows its chat, and any
  /// other session (a parent, a creator, a fork) shows with its own tabs.
  func openSession(
    _ sessionID: String, from sourceID: String, in ownerID: String,
    openChild: @MainActor (String) -> Void
  ) {
    let list = session.connection.sessionList
    if sessionID == ownerID {
      groups.showChat(ownerID)
    } else if knownChildren(of: ownerID, and: sourceID)
      .runs(sessionID, under: ownerID, listedParent: { list.parent(of: $0) })
    {
      openChild(sessionID)
    } else {
      groups.show(.session(sessionID))
    }
  }

  /// A terminal's or side question's Show Chat: the tab of the conversation it came from, which
  /// for a side chat's or sub-agent's is in the same strip.
  func showConversation(_ sessionID: String, fromTab tabID: String) {
    let ownerID = groups.tab(tabID)?.sessionID ?? sessionID
    if ownerID == sessionID {
      groups.showChat(sessionID)
    } else {
      openChild(sessionID, from: ownerID, in: ownerID)
    }
  }

  /// A `/side` typed in `sessionID`'s composer is going to an agent that forks the side chat
  /// itself: the fork arrives as a new child of `sessionID` and opens in a tab of `ownerID`,
  /// however long it takes (web `awaitingSideChatFor`).
  /// - Returns: The wait, to withdraw when the message is not sent; `nil` when the
  ///   conversation is not open.
  func awaitForkedSideChat(of sessionID: String, in ownerID: String) -> ForkedSideChats.WaitID? {
    guard let conversation = session.connection.openConversation(sessionID) else { return nil }
    let groups = groups
    // Nothing shows for it until the fork opens; a closed session has no fork to show.
    return session.forkedSideChats.awaitFork(
      of: conversation, gaveUp: {},
      forked: { groups.openChild($0, in: ownerID, isSideChat: true, name: nil) })
  }

  private func knownChildren(of ownerID: String, and sourceID: String) -> KnownChildren {
    let connection = session.connection
    return KnownChildren(Set([ownerID, sourceID]).compactMap(connection.openConversation))
  }
}

extension SessionTabGroups {
  /// Selects the tab of a sub-agent or side chat in its owner's strip, opening one when none
  /// shows it. The window's page is left as it is.
  /// - Parameters:
  ///   - childID: The sub-agent or side chat.
  ///   - ownerID: The session it runs under, whose strip it joins.
  ///   - isSideChat: It opens as a side chat, "Side chat N", rather than a sub-agent.
  ///   - name: A sub-agent's name, as the agent list shows it.
  ///   - select: Selects the tab; otherwise a new one opens behind the selected tab.
  /// - Returns: The tab.
  @discardableResult
  func openChild(
    _ childID: String, in ownerID: String, isSideChat: Bool, name: String?, select: Bool = true
  ) -> AppTab {
    let group = group(ownerID)
    if let shown = group.tabs.first(where: { $0.content.conversationID == childID }) {
      if select { group.select(shown.id) }
      return shown
    }
    let content: AppTabContent =
      isSideChat
      ? .sideChatSession(parentID: ownerID, childID: childID)
      : .subagent(parentID: ownerID, childID: childID)
    return group.open(content, select: select, title: isSideChat ? nil : name)
  }
}
