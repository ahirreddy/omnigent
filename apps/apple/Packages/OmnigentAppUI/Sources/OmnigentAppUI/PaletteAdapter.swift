import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// Palette data and navigation over the connected window's existing stores.
struct PaletteAdapter: ViewModifier {
  let session: ServerSession
  @Binding var selection: SidebarDestination?

  func body(content: Content) -> some View {
    content.commandPalette(state: state, actions: PaletteActions(perform: perform))
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
    return PaletteViewState(
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
  }

  private func status(_ summary: OmnigentUIComponents.SessionSummary) -> String {
    switch summary.status {
    case .needsResponse: "Needs you"
    case .running: "Working"
    case .idle: summary.failureMessage == nil ? "Ready" : "Failed"
    }
  }

  private func perform(_ target: PaletteTarget) {
    switch target {
    case .newSession: selection = .newSession
    case .inbox: selection = .inbox
    case .session(let id): selection = .session(id)
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
    case .findSession, .switchServer, .changes, .composer, .toggleTerminal:
      break
    }
  }
}
