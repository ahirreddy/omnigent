import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// Palette data and navigation over the connected window's existing stores.
struct PaletteAdapter: ViewModifier {
  let session: ServerSession
  @Binding var selection: SidebarDestination?
  @Environment(\.openSettingsAt) private var openSettingsAt
  #if os(iOS)
    @State private var sidebarToggle = SidebarToggle()
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
      let content = content.environment(\.sidebarToggle, sidebarToggle)
    #endif
    return content.commandPalette(
      state: { state }, actions: PaletteActions(perform: perform, search: searchServer(_:limit:)))
  }

  var state: PaletteViewState {
    let connection = session.connection
    let directory = session.signIn.directory
    let managed = directory.managed.map {
      PaletteEntry(
        id: $0.url, title: $0.displayName, detail: "Organization server", symbol: "server.rack",
        target: .server($0.url))
    }
    let managedURLs = Set(directory.managed.map(\.url))
    let recent =
      directory.serversAreForced
      ? []
      : directory.recentServers.filter { !managedURLs.contains($0) }.map {
        PaletteEntry(
          id: $0, title: URL(string: $0)?.host() ?? $0, detail: "Recent server",
          symbol: "server.rack", target: .server($0))
      }
    var state = PaletteViewState(
      scope: connection.connectedServer?.serverName ?? "Connected server",
      sessions: connection.sessionList.sessionsByID.values.sorted { $0.updatedAt > $1.updatedAt }
        .map {
          let summary = OmnigentUIComponents.SessionSummary($0)
          return PaletteEntry(
            id: "session-\(summary.id)", title: summary.title,
            detail: "\(status(summary)) · \(summary.agentName) · \(summary.workspace)",
            symbol: "bubble.left.and.text.bubble.right", target: .session(summary.id),
            breadcrumb: breadcrumb(summary, core: $0))
        }, servers: managed + recent,
      hasNextRequest: !connection.sessionList.needsResponse.isEmpty)
    // Gated as the sidebar rows are, on what the server offers.
    state.showsAutomations = connection.pages?.offered?.automations == true
    state.showsUsage = connection.pages?.offered?.usage == true
    return state
  }

  /// Server matches: titles, and message content ("In messages") with its snippet.
  func searchServer(_ query: String, limit: Int) async -> PaletteSearchResults {
    let list = session.connection.sessionList
    do {
      let titles = try await list.search(query, inMessages: false, limit: UInt32(limit))
      let content = try await list.search(query, inMessages: true, limit: UInt32(limit))
      var results = PaletteSearchResults(
        titles: titles.map { summary in
          entry(summary, detail: nil, prefix: "found")
        },
        messages: content.map { summary in
          entry(summary, detail: summary.preview, prefix: "message")
        })
      results.hasMore = titles.count >= limit || content.count >= limit
      return results
    } catch {
      return PaletteSearchResults(failure: error.message)
    }
  }

  private func entry(
    _ core: OmnigentCoreFFI.SessionSummary, detail: String?, prefix: String
  ) -> PaletteEntry {
    let summary = OmnigentUIComponents.SessionSummary(core)
    return PaletteEntry(
      id: "\(prefix)-\(summary.id)", title: summary.title,
      detail: detail ?? "\(status(summary)) · \(summary.agentName) · \(summary.workspace)",
      symbol: detail == nil ? "bubble.left.and.text.bubble.right" : "text.magnifyingglass",
      target: .session(summary.id), breadcrumb: breadcrumb(summary, core: core))
  }

  /// A nested session's breadcrumb, as the web's search rows: its project folder, then the
  /// session it is nested under.
  private func breadcrumb(
    _ summary: OmnigentUIComponents.SessionSummary, core: OmnigentCoreFFI.SessionSummary
  ) -> PaletteBreadcrumb? {
    guard summary.isNestedMember else { return nil }
    let list = session.connection.sessionList
    let project = zip(list.projects, list.members(of: [core])).first { !$0.1.isEmpty }?.0.name
    return .nested(
      summary, project: project, loadedTitle: { list.sessionWithoutActivity($0)?.title })
  }

  private func status(_ summary: OmnigentUIComponents.SessionSummary) -> String {
    // The web badges archived matches.
    if summary.isArchived { return "Archived" }
    return switch summary.status {
    case .needsResponse: "Needs you"
    case .running: "Working"
    case .idle: summary.failureMessage == nil ? "Ready" : "Failed"
    }
  }

  /// The sidebar destination a palette entry opens, if it is one.
  private static func destination(_ target: PaletteTarget) -> SidebarDestination? {
    switch target {
    case .newSession: .newSession
    case .inbox: .inbox
    case .automations: .automations
    case .usage: .usage
    case .session(let id): .session(id)
    default: nil
    }
  }

  func perform(_ target: PaletteTarget) {
    if let destination = Self.destination(target) {
      selection = destination
      return
    }
    switch target {
    case .nextRequest:
      let ids = session.connection.sessionList.needsResponse.map(\.id)
      if let current = selection?.sessionID, let index = ids.firstIndex(of: current), !ids.isEmpty {
        selection = .session(ids[(index + 1) % ids.count])
      } else if let first = ids.first {
        selection = .session(first)
      }
    case .server(let url):
      selection = nil
      session.signIn.connect(url)
    case .settings:
      openSettingsAt?(.tab(SettingsNavigator.generalTab))
    case .toggleSidebar:
      #if os(macOS)
        // The split view's own toggle, as View > Show Sidebar sends it.
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
      #else
        sidebarToggle()
      #endif
    case .newSession, .inbox, .automations, .usage, .session, .findSession, .switchServer,
      .changes, .composer, .toggleTerminal, .toggleInspector:
      break
    }
  }
}
