public import OmnigentDeepLinks
public import OmnigentUIComponents

/// Where a page or settings link lands in the app, shared by the Mac windows and the iPhone and
/// iPad scenes.
public enum DeepLinkDestinations {
  /// The sidebar destination of a page link.
  /// - Parameter page: The page.
  /// - Returns: The destination.
  public static func selection(for page: DeepLinkPage) -> SidebarDestination {
    switch page {
    case .newSession: .newSession
    case .inbox: .inbox
    case .automations: .automations
    case .usage: .usage
    case .canvas: .canvas
    }
  }

  /// The Settings place of `/settings/<section>`, by the web's section ids: the app's own tabs,
  /// else `server`'s pane. Unknown sections open General.
  /// - Parameters:
  ///   - section: The web's section id, `nil` for `/settings`.
  ///   - server: The window's server.
  /// - Returns: The destination.
  public static func settings(section: String?, server: String?) -> SettingsDestination {
    switch section {
    case "appearance": return .tab(SettingsNavigator.appearanceTab)
    case "notifications": return .tab(SettingsNavigator.notificationsTab)
    case "terminal": return .tab(SettingsNavigator.terminalTab)
    default: break
    }
    guard let pane = section.flatMap(serverPane) else {
      return .tab(SettingsNavigator.generalTab)
    }
    return .server(url: server, pane: pane)
  }

  /// The server pane for a web settings section id.
  static func serverPane(_ section: String) -> ServerSettingsPane? {
    switch section {
    case "custom-agents": .customAgents
    case "import": .importSessions
    default: ServerSettingsPane(rawValue: section)
    }
  }
}
