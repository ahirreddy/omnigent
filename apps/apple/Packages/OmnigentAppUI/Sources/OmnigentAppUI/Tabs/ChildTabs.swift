import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

// A session's sub-agents and forked side chats show in tabs of that session's strip, beside its
// chat, as the web shows them in the parent's panel. They never take the window as a session.

extension ConversationStore {
  /// The sessions the stream reported under this one (sub-agents, an agent's own side-chat
  /// forks), in the order they started, with the names their rows show.
  var listedChildren: [(id: String, name: String)] {
    sections.compactMap { section in
      guard section.id.hasPrefix("child-"), let id = section.sessionId else { return nil }
      return (id, section.title)
    }
  }
}

/// What a group's open conversations know of the sessions under them: each one's parent and the
/// name it is listed under (the stream's child rows, the Agents tab's tree).
struct KnownChildren {
  private(set) var parents: [String: String] = [:]
  private(set) var names: [String: String] = [:]

  init(_ conversations: [ConversationStore]) {
    for conversation in conversations {
      for child in conversation.listedChildren {
        parents[child.id] = conversation.sessionID
        names[child.id] = child.name
      }
      for node in conversation.tools.agentTree?.nodes ?? [] {
        if let parentID = node.parentId { parents[node.sessionId] = parentID }
        names[node.sessionId] = node.name
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
/// nothing to pair it on, so each wait takes the next child the session did not have, oldest
/// wait first.
final class ForkedSideChats {
  typealias WaitID = UUID
  /// Withdraws a wait whose request was not sent.
  typealias Withdraw = @MainActor () -> Void

  private struct Wait {
    let id: WaitID
    let forked: @MainActor (String) -> Void
    let gaveUp: @MainActor () -> Void
    let timeout: Task<Void, Never>
  }

  private struct Parent {
    /// The children the session had before its oldest wait, and those paired since.
    var known: Set<String>
    var waits: [Wait] = []
    var watch: Task<Void, Never>?
  }

  private var parents: [String: Parent] = [:]
  /// How long a fork may take to be reported before its wait gives up.
  var patience: Duration = .seconds(60)

  /// Queues a wait for the next new child of `conversation`. Call it before the request that
  /// asks for the fork, so waits pair in the order their requests went.
  /// - Parameters:
  ///   - conversation: The session whose agent forks.
  ///   - gaveUp: No fork was reported in time, or the session closed.
  ///   - forked: The fork's session.
  /// - Returns: The wait, to ``cancel(_:of:)`` when the request is refused.
  @discardableResult
  func awaitFork(
    of conversation: ConversationStore, gaveUp: @escaping @MainActor () -> Void,
    forked: @escaping @MainActor (String) -> Void
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
      if self?.remove(id, of: parentID) == true { gaveUp() }
    }
    var parent = parents[parentID] ?? Parent(known: Set(conversation.listedChildren.map(\.id)))
    parent.waits.append(Wait(id: id, forked: forked, gaveUp: gaveUp, timeout: timeout))
    if parent.watch == nil { parent.watch = watch(conversation) }
    parents[parentID] = parent
    return id
  }

  /// Withdraws a wait whose request was not sent: no fork comes for it.
  func cancel(_ id: WaitID, of parentID: String) {
    remove(id, of: parentID)
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

  private func watch(_ conversation: ConversationStore) -> Task<Void, Never> {
    let parentID = conversation.sessionID
    return Task { [weak self] in
      for await children in Observations({ conversation.listedChildren.map(\.id) }) {
        guard !Task.isCancelled, let self else { return }
        pair(children, of: parentID)
      }
    }
  }

  /// Hands each child the session did not have to the oldest wait, in the order they started.
  private func pair(_ children: [String], of parentID: String) {
    guard var parent = parents[parentID] else { return }
    var paired: [(wait: Wait, childID: String)] = []
    for childID in children where !parent.known.contains(childID) && !parent.waits.isEmpty {
      parent.known.insert(childID)
      paired.append((parent.waits.removeFirst(), childID))
    }
    keep(parent, for: parentID)
    for (wait, childID) in paired {
      wait.timeout.cancel()
      wait.forked(childID)
    }
  }

  @discardableResult
  private func remove(_ id: WaitID, of parentID: String) -> Bool {
    guard var parent = parents[parentID],
      let index = parent.waits.firstIndex(where: { $0.id == id })
    else { return false }
    parent.waits.remove(at: index).timeout.cancel()
    keep(parent, for: parentID)
    return true
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
  /// it, else a window of its own when `apart` is given, else a new tab in `ownerID`'s strip.
  /// - Parameters:
  ///   - childID: The child session.
  ///   - sourceID: The conversation that listed it, for its name.
  ///   - ownerID: The session whose tabs it joins.
  ///   - apart: Opens it in another window (Settings › Open sub-agents in a new window).
  func openChild(
    _ childID: String, from sourceID: String, in ownerID: String,
    apart: (@MainActor (String) -> Void)? = nil
  ) {
    let group = groups.group(ownerID)
    if let shown = group.tabs.first(where: { $0.content.conversationID == childID }) {
      group.select(shown.id)
    } else if let apart {
      apart(childID)
      return
    } else {
      let name = knownChildren(of: ownerID, and: sourceID).names[childID]
      group.open(.subagent(parentID: ownerID, childID: childID), title: name)
    }
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
  /// itself: the fork arrives as a new child of `sessionID` and opens in a tab of `ownerID`.
  /// - Returns: The wait, to withdraw when the message is not sent; `nil` when the
  ///   conversation is not open.
  func awaitForkedSideChat(of sessionID: String, in ownerID: String) -> ForkedSideChats.WaitID? {
    guard let conversation = session.connection.openConversation(sessionID) else { return nil }
    let groups = groups
    let fail = fail
    return session.forkedSideChats.awaitFork(
      of: conversation,
      gaveUp: { fail("The agent didn't report a side chat for your /side question.") },
      forked: { childID in
        let group = groups.group(ownerID)
        if let shown = group.tabs.first(where: { $0.content.conversationID == childID }) {
          group.select(shown.id)
        } else {
          group.open(.sideChatSession(parentID: ownerID, childID: childID))
        }
      })
  }

  private func knownChildren(of ownerID: String, and sourceID: String) -> KnownChildren {
    let connection = session.connection
    return KnownChildren(Set([ownerID, sourceID]).compactMap(connection.openConversation))
  }
}
