import OmnigentCoreFFI
import OmnigentStores
import SwiftUI

/// Removes a session's tabs, its primary chat among them, once the session is archived or
/// deleted, here or on another device. It is the only way a primary chat leaves a window
/// besides closing the window.
///
/// Only changes between two loaded lists count, so a session that was never in the list (a
/// sub-agent opened from its parent) or one opened from the Archived filter keeps its tabs.
struct SessionTabsLifecycle: ViewModifier {
  let session: ServerSession

  @State private var known = SessionPresence()

  func body(content: Content) -> some View {
    content.onChange(of: presence, initial: true) { _, current in
      defer { known = current }
      guard known.isLoaded, current.isLoaded else { return }
      let gone = Self.departed(previous: known.archivedByID, current: current.archivedByID)
      if !gone.isEmpty { session.tabs.removeSessions(gone) }
    }
  }

  /// Each known session's archived flag, once the list has loaded.
  private var presence: SessionPresence {
    let list = session.connection.sessionList
    guard list.isLoaded else { return SessionPresence() }
    return SessionPresence(isLoaded: true, archivedByID: list.sessionsByID.mapValues(\.isArchived))
  }

  /// The sessions deleted (gone from the list) or archived between two lists.
  /// - Parameters:
  ///   - previous: Archived flags by session id, before.
  ///   - current: Archived flags by session id, now.
  /// - Returns: The sessions whose tabs should leave.
  static func departed(previous: [String: Bool], current: [String: Bool]) -> Set<String> {
    Set(
      previous.compactMap { id, wasArchived in
        guard let isArchived = current[id] else { return id }
        return !wasArchived && isArchived ? id : nil
      })
  }
}

/// The session list as far as tabs care: whether it has loaded, and which sessions are archived.
struct SessionPresence: Equatable {
  var isLoaded = false
  var archivedByID: [String: Bool] = [:]
}
