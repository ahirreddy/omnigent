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

/// The sessions whose agent was sent a typed `/side` and has not reported its fork yet (web
/// `awaitingSideChatFor`). Each waits for the first child it did not have when the message went.
final class ForkedSideChats {
  private var waits: [String: Task<Void, Never>] = [:]

  /// Hands `opened` the next new child of `conversation`, once.
  func awaitFork(
    of conversation: ConversationStore, opened: @escaping @MainActor (String) -> Void
  ) {
    let parentID = conversation.sessionID
    let known = Set(conversation.listedChildren.map(\.id))
    waits[parentID]?.cancel()
    waits[parentID] = Task { [weak self] in
      for await children in Observations({ conversation.listedChildren.map(\.id) }) {
        // A newer `/side`, or a message that was not sent, cancelled this wait.
        guard !Task.isCancelled else { return }
        guard let forked = children.first(where: { !known.contains($0) }) else { continue }
        opened(forked)
        break
      }
      // A cancelled wait's place may be a newer one's now.
      if !Task.isCancelled { self?.waits[parentID] = nil }
    }
  }

  /// Stops waiting: the message was not sent, or the session closed.
  func cancel(_ parentID: String) {
    waits.removeValue(forKey: parentID)?.cancel()
  }

  /// Whether a fork of `parentID` is awaited.
  func isAwaiting(_ parentID: String) -> Bool { waits[parentID] != nil }
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

  /// A typed `/side` went to an agent that forks the side chat itself: the fork arrives as a new
  /// child of `sessionID` and opens in a tab of `ownerID`. A message that was not sent awaits
  /// nothing.
  func awaitForkedSideChat(of sessionID: String, in ownerID: String, sent: Bool) {
    let awaited = session.forkedSideChats
    guard sent, let conversation = session.connection.openConversation(sessionID) else {
      awaited.cancel(sessionID)
      return
    }
    let groups = groups
    awaited.awaitFork(of: conversation) { childID in
      let group = groups.group(ownerID)
      if let shown = group.tabs.first(where: { $0.content.conversationID == childID }) {
        group.select(shown.id)
      } else {
        group.open(.sideChatSession(parentID: ownerID, childID: childID))
      }
    }
  }

  private func knownChildren(of ownerID: String, and sourceID: String) -> KnownChildren {
    let connection = session.connection
    return KnownChildren(Set([ownerID, sourceID]).compactMap(connection.openConversation))
  }
}
