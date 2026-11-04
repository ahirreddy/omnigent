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
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  func body(content: Content) -> some View {
    content.commandPalette(
      state: state, actions: PaletteActions(perform: perform, search: searchServer))
  }

  private var state: PaletteViewState {
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
            symbol: "bubble.left.and.text.bubble.right", target: .session(summary.id))
        }, servers: managed + recent,
      hasNextRequest: !connection.sessionList.needsResponse.isEmpty)
    // Gated as the sidebar rows are, on what the server offers.
    state.showsAutomations = connection.pages?.offered?.automations == true
    state.showsUsage = connection.pages?.offered?.usage == true
    return state
  }

  /// Server matches: titles first, then message content ("In messages") with its snippet.
  private func searchServer(_ query: String) async -> [PaletteEntry] {
    let list = session.connection.sessionList
    do {
      let titles = try await list.search(query, inMessages: false)
      let content = try await list.search(query, inMessages: true)
      let titleEntries = titles.map { summary in
        entry(OmnigentUIComponents.SessionSummary(summary), detail: nil, prefix: "found")
      }
      let contentEntries = content.map { summary in
        entry(
          OmnigentUIComponents.SessionSummary(summary), detail: "In messages: \(summary.preview)",
          prefix: "message")
      }
      return titleEntries + contentEntries
    } catch {
      return [
        PaletteEntry(
          id: "search-failed", title: "Could not search the server", detail: error.message,
          symbol: "exclamationmark.triangle", isEnabled: false, target: .findSession)
      ]
    }
  }

  private func entry(
    _ summary: OmnigentUIComponents.SessionSummary, detail: String?, prefix: String
  ) -> PaletteEntry {
    PaletteEntry(
      id: "\(prefix)-\(summary.id)", title: summary.title,
      detail: detail ?? "\(status(summary)) · \(summary.agentName) · \(summary.workspace)",
      symbol: detail == nil ? "bubble.left.and.text.bubble.right" : "text.magnifyingglass",
      target: .session(summary.id))
  }

  private func status(_ summary: OmnigentUIComponents.SessionSummary) -> String {
    switch summary.status {
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

  private func perform(_ target: PaletteTarget) {
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
      #if os(macOS)
        openSettings()
      #endif
    case .toggleSidebar:
      #if os(macOS)
        // The split view's own toggle, as View > Show Sidebar sends it.
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
      #endif
    case .newSession, .inbox, .automations, .usage, .session, .findSession, .switchServer,
      .changes, .composer, .toggleTerminal, .toggleInspector:
      break
    }
  }
}
