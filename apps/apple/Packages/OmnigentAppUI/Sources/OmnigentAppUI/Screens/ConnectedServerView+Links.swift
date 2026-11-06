import Foundation
import OmnigentCoreFFI
import OmnigentDeepLinks
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

// Clicked links to this server's web app open where the app shows them.
extension ConnectedServerView {
  /// Opens links to the connected server's web app (`…/c/<id>`, `?message=`, `/settings/<x>`,
  /// `/usage`) in this window, and everything else with `fallback`.
  /// - Parameters:
  ///   - fallback: The browser opener.
  ///   - openSettings: The window's Settings, for settings links.
  /// - Returns: The opener.
  func serverLinkOpener(
    _ fallback: ExternalURLOpener, openSettings: OpenSettingsDestinationAction?
  ) -> ExternalURLOpener {
    let baseURL = connection.connectedServer?.baseUrl
    let server = baseURL.flatMap(URL.init(string:))
    // iPhone and iPad Settings show the scene's own server.
    #if os(macOS)
      let settingsServer = baseURL
    #else
      let settingsServer: String? = nil
    #endif
    let selection = selectionBinding
    let focus = session.transcriptFocus
    return ExternalURLOpener { url in
      guard let server, let route = DeepLinkRoute(webURL: url, server: server) else {
        return await fallback.open(url)
      }
      switch route {
      case .home, .register:
        selection.wrappedValue = nil
      case .conversation(let sessionID):
        selection.wrappedValue = .session(sessionID)
      case .message(let sessionID, let messageID):
        focus.focus(messageID, in: sessionID)
        selection.wrappedValue = .session(sessionID)
      case .page(let page):
        selection.wrappedValue = DeepLinkDestinations.selection(for: page)
      case .settings(let section):
        guard let openSettings else { return await fallback.open(url) }
        openSettings(DeepLinkDestinations.settings(section: section, server: settingsServer))
      }
      return true
    }
  }
}
