import OmnigentCoreFFI
import OmnigentStores
import SwiftUI

/// Removes a session's tabs, its primary chat among them, once the session is archived or
/// deleted, here or on another device. It is the only way a primary chat leaves a window
/// besides closing the window. A session this app is archiving, deleting or leaving keeps its
/// tabs until the server answers, though its row has left the list.
///
/// Only changes between two loaded lists count, so a session that was never in the list (a
/// sub-agent opened from its parent) or one opened from the Archived filter keeps its tabs.
/// A tab saved before its session was deleted leaves when the server says the session is missing.
struct SessionTabsLifecycle: ViewModifier {
  let session: ServerSession

  @State private var known = SessionPresence()

  func body(content: Content) -> some View {
    content.onChange(of: presence, initial: true) { _, latest in
      let current = latest.holding(known)
      defer { known = current }
      guard known.isLoaded, current.isLoaded else { return }
      let gone = Self.departed(previous: known.archivedByID, current: current.archivedByID)
      if !gone.isEmpty { session.tabs.removeSessions(gone) }
    }
    .onChange(of: missingSessions, initial: true) { _, missing in
      if !missing.isEmpty { session.tabs.removeSessions(missing) }
    }
  }

  /// The open sessions the server says no longer exist.
  private var missingSessions: Set<String> {
    let list = session.connection.sessionList
    let answers = session.openSessionIDs.compactMap { id in
      session.connection.conversations[id].map { conversation in
        SessionAnswer(
          id: id, isClosed: conversation.isClosed,
          answeredNotFound: conversation.answeredNotFoundBeforeLoading)
      }
    }
    return Self.missing(answers, isListLoaded: list.isLoaded, listed: Set(list.sessionsByID.keys))
  }

  /// A closed session is gone. A 404 alone can be a proxy whose backend is restarting, so it
  /// counts once a loaded list, read from the same server, doesn't have the session either.
  /// - Parameters:
  ///   - answers: What the server said about each open session.
  ///   - isListLoaded: Whether the session list has loaded.
  ///   - listed: The sessions in that list.
  /// - Returns: The sessions whose tabs should leave.
  static func missing(
    _ answers: [SessionAnswer], isListLoaded: Bool, listed: Set<String>
  ) -> Set<String> {
    Set(
      answers.filter { answer in
        if answer.isClosed { return true }
        return answer.answeredNotFound && isListLoaded && !listed.contains(answer.id)
      }
      .map(\.id))
  }

  /// Each known session's archived flag, once the list has loaded.
  private var presence: SessionPresence {
    let list = session.connection.sessionList
    guard list.isLoaded else { return SessionPresence() }
    return SessionPresence(
      isLoaded: true, archivedByID: list.sessionsByID.mapValues(\.isArchived),
      departing: list.departing)
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

/// What the server said about one open session.
struct SessionAnswer: Equatable {
  var id: String
  /// The session was removed, or its stream gave up on repeated 404s.
  var isClosed: Bool
  /// It answered 404 before ever loading.
  var answeredNotFound: Bool
}

/// The session list as far as tabs care: whether it has loaded, and which sessions are archived.
struct SessionPresence: Equatable {
  var isLoaded = false
  var archivedByID: [String: Bool] = [:]
  /// Sessions leaving the list whose archive, delete or leave the server has not answered.
  var departing: Set<String> = []

  /// This presence with each departing session as `known` had it: its row left at the click,
  /// and its tabs stay until the server agrees. A refused one is back before it stops departing.
  func holding(_ known: Self) -> Self {
    var held = self
    for id in departing { held.archivedByID[id] = known.archivedByID[id] }
    return held
  }
}
