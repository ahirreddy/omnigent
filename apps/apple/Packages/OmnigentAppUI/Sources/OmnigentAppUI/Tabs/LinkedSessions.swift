import Foundation
import OSLog
import OmnigentCoreFFI
import OmnigentStores
public import OmnigentUIComponents

// A deep link or a notification can name a sub-agent or a side chat. It opens as a tab of the
// session it runs under, as the agent list opens it, never as a session of its own.

/// Where a sub-agent or side chat shows: a tab in the strip of the top-level session it runs
/// under.
struct ChildPlacement: Equatable {
  /// The top-level session whose strip it joins.
  var ownerID: String
  /// It opens as a side chat, "Side chat N".
  var isSideChat: Bool
  /// A sub-agent's name, as the agent list shows it.
  var name: String?
}

extension ServerSession {
  /// Shows the session a deep link or notification names, its chat in front. A sub-agent or
  /// side chat opens or focuses its tab in the strip of the top-level session it runs under;
  /// any other session shows with its own tabs.
  /// - Parameter sessionID: The session the link names.
  /// - Returns: The page that shows it, for the window's selection.
  @discardableResult
  public func showLinkedSession(_ sessionID: String) async -> SidebarDestination {
    guard let placement = await childPlacement(of: sessionID) else {
      tabs.showChat(sessionID)
      return .session(sessionID)
    }
    tabs.openChild(
      sessionID, in: placement.ownerID, isSideChat: placement.isSideChat, name: placement.name)
    tabs.show(.session(placement.ownerID))
    return .session(placement.ownerID)
  }

  /// Where `sessionID` shows when it runs under another session; `nil` for a top-level one. A
  /// session this window knows nothing of is looked up in its agent tree.
  func childPlacement(of sessionID: String) async -> ChildPlacement? {
    if let known = knownPlacement(of: sessionID) { return known }
    // A listed session with no known parent is a top-level one.
    guard connection.sessionList.sessionWithoutActivity(sessionID) == nil,
      let core = connection.core
    else { return nil }
    let tree: AgentTree
    do {
      tree = try await core.agentTree(sessionId: sessionID)
    } catch {
      // It still opens, as a session of its own.
      Logger(subsystem: "ai.omnigent.app", category: "tabs").error(
        "A linked session's parent is unknown: \(String(describing: error), privacy: .public)")
      return nil
    }
    guard tree.rootId != sessionID else { return nil }
    let node = tree.nodes.first { $0.sessionId == sessionID }
    return ChildPlacement(
      ownerID: tree.rootId, isSideChat: node?.isSideChat ?? false, name: node?.name)
  }

  /// `sessionID`'s place from what the open conversations and the session list know of it.
  func knownPlacement(of sessionID: String) -> ChildPlacement? {
    let known = KnownChildren(openSessionIDs.compactMap(connection.openConversation))
    let list = connection.sessionList
    let connection = connection
    let parent = { (id: String) -> String? in
      if let parent = known.parents[id] ?? list.parent(of: id) { return parent }
      let settings = connection.openConversation(id)?.header?.settings
      return [settings?.parentId, settings?.sideChatSourceId].lazy.compactMap(\.self)
        .first { !$0.isEmpty && $0 != id }
    }
    guard var ownerID = parent(sessionID) else { return nil }
    // A bound on the walk, so a parent link that loops ends it.
    for _ in 0..<32 {
      guard let next = parent(ownerID), next != sessionID else { break }
      ownerID = next
    }
    let settings = connection.openConversation(sessionID)?.header?.settings
    return ChildPlacement(
      ownerID: ownerID,
      isSideChat: known.sideChats.contains(sessionID) || settings?.isSideChat == true,
      name: known.names[sessionID])
  }
}
