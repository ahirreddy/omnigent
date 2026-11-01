import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the sidebar's view state from the session list and the badge. Ordering, search and
/// filtering stay the core's (`filterSessions`); the sidebar renders them as given.
enum SidebarAdapter {
  /// The sidebar's view state.
  /// - Parameters:
  ///   - list: The session list.
  ///   - notifications: The badge, which marks unread sessions.
  ///   - display: The user's display options.
  ///   - server: The connected server, offered in the server switcher.
  /// - Returns: The state.
  static func state(
    list: SessionListStore, notifications: NotificationsStore?, display: SessionDisplayOptions,
    server: ConnectedServer?
  ) -> SidebarViewState {
    let all = Array(list.sessionsByID.values)
    var counts: [OmnigentUIComponents.SessionFilter: Int] = [:]
    for filter in OmnigentUIComponents.SessionFilter.allCases {
      counts[filter] = filterSessions(
        sessions: all, text: "", filter: OmnigentCoreFFI.SessionFilter(filter)
      ).count
    }
    let filter = OmnigentUIComponents.SessionFilter(list.filter)
    let listState = SessionListViewState(
      sessions: list.visible.map(OmnigentUIComponents.SessionSummary.init), filter: filter,
      unreadIds: Set(notifications?.badgeSessionIDs ?? []), filterCounts: counts,
      phase: phase(list))
    let servers = server.map { [ServerChoice($0)] } ?? []
    return SidebarViewState(
      list: listState, inboxCount: counts[.needsResponse] ?? 0, showsCanvas: false,
      display: display, quickFilter: filter == .all ? nil : filter, servers: servers,
      currentServerID: servers.first?.id)
  }

  static func phase(_ list: SessionListStore) -> SessionListPhase {
    if let error = list.lastError { return .failed(message: error.message) }
    return list.isLoaded ? .loaded : .loading
  }

  /// The web page of a session, as the core builds it (`<server>/c/<id>`, keeping any mount).
  static func webURL(server: ConnectedServer?, sessionID: String) -> URL? {
    guard let server else { return nil }
    do {
      return URL(
        string: try conversationUrl(
          serverUrl: server.baseUrl, route: .conversation(sessionId: sessionID)))
    } catch {
      // The row menu hides Copy Link for a session without a web URL; the server URL itself was
      // already validated by the core on connect.
      return nil
    }
  }
}

extension ServerChoice {
  init(_ server: ConnectedServer) {
    self.init(
      id: server.baseUrl,
      name: server.serverName ?? URLComponents(string: server.baseUrl)?.host ?? server.baseUrl,
      url: server.baseUrl, isConnected: true)
  }
}
