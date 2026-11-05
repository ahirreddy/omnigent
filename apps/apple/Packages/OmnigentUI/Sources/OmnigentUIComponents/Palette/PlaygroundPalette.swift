import SwiftUI

extension PlaygroundModel {
  var paletteState: PaletteViewState {
    PaletteViewState(
      scope: "Mac Studio",
      sessions: sidebar.list.sessions.map {
        PaletteEntry(
          id: $0.id, title: $0.title, detail: "\($0.agentName) · \($0.preview)",
          symbol: "bubble.left.and.text.bubble.right", target: .session($0.id))
      },
      servers: [
        PaletteEntry(
          id: "studio", title: "Mac Studio", detail: "Current server", symbol: "server.rack",
          target: .server("studio")),
        PaletteEntry(
          id: "build", title: "Build Mac", detail: "Development", symbol: "server.rack",
          target: .server("build")),
      ], hasNextRequest: true)
  }

  var paletteActions: PaletteActions {
    PaletteActions { [weak self] target in
      guard let self else { return }
      switch target {
      case .newSession: selection = .newSession
      case .session(let id): selection = .session(id)
      case .inbox: scenario = .inboxTriage
      case .nextRequest: scenario = .approvals
      case .server: scenario = .serverSettings
      case .findSession, .switchServer, .changes, .composer, .toggleTerminal, .settings,
        .toggleSidebar, .toggleInspector, .automations, .usage:
        break
      }
    }
  }
}
