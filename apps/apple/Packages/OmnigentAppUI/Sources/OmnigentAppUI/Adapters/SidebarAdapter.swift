import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the sidebar's view state from the session list. Ordering, search and filtering stay the
/// core's (`filterSessions`); every attention glyph and count comes from the list's shared
/// attention model (`SessionListStore.attention(of:)` and `attentionTotals`), so the row, the
/// Running and Needs you counts and the Inbox badge agree with the Dock and menu bar.
enum SidebarAdapter {
  /// The sidebar's view state.
  /// - Parameters:
  ///   - list: The session list.
  ///   - display: The user's display options.
  ///   - server: The connected server, offered in the server switcher.
  /// - Returns: The state.
  static func state(
    list: SessionListStore, display: SessionDisplayOptions, server: ConnectedServer?
  ) -> SidebarViewState {
    let all = Array(list.sessionsByID.values)
    let totals = list.attentionTotals
    var counts: [OmnigentUIComponents.SessionFilter: Int] = [
      .running: Int(totals.working), .needsResponse: Int(totals.sessionsNeedingYou),
    ]
    for filter in [OmnigentUIComponents.SessionFilter.all, .archived] {
      counts[filter] =
        filterSessions(
          sessions: all, text: "", filter: OmnigentCoreFFI.SessionFilter(filter)
        ).count
    }
    let requests = list.attentionByID.compactMapValues { attention in
      attention.state == .needsYou ? Int(attention.requests) : nil
    }
    let filter = OmnigentUIComponents.SessionFilter(list.filter)
    let listState = SessionListViewState(
      sessions: list.visible.map {
        OmnigentUIComponents.SessionSummary($0, attention: list.attention(of: $0.id))
      },
      filter: filter, unreadIds: list.unreadIDs, attentionCounts: requests, filterCounts: counts,
      phase: phase(list))
    let servers = server.map { [ServerChoice($0)] } ?? []
    return SidebarViewState(
      list: listState, inboxCount: Int(totals.sessionsNeedingYou), showsCanvas: false,
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
      name: ExecutionContext.serverDisplayName(name: server.serverName, baseURL: server.baseUrl),
      url: server.baseUrl, isConnected: true)
  }
}
