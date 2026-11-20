import Foundation
import OmnigentAppUI
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

#if OMNIGENT_CHROMIUM
  import OmnigentDesktopUpdate
#endif

extension ServerWindowRoot {
  /// The window's Settings page, over everything else the window shows.
  func settingsPage(_ settings: SettingsNavigator) -> some View {
    #if OMNIGENT_CHROMIUM
      AppSettingsView(services: services, updater: updater, navigator: settings)
    #else
      AppSettingsView(services: services, navigator: settings)
    #endif
  }

  /// How Omnigent > Settings and the menu bar show and leave a window's Settings page.
  static func windowPage(_ settings: SettingsNavigator) -> WindowSettingsPage {
    WindowSettingsPage(
      isShown: { settings.isPresented },
      setShown: { isShown in
        if isShown { settings.open() } else { settings.close() }
      })
  }

  /// A link or a notification that takes the window somewhere shows it there, not Settings.
  static func leavesSettings(_ route: OmnigentDesktop.DeepLinkRoute) -> Bool {
    if case .settings = route { return false }
    return true
  }

  /// Follows a link or a notification in this window, leaving Settings unless it leads there.
  func follow(
    _ route: OmnigentDesktop.DeepLinkRoute, in session: ServerSession, settings: SettingsNavigator
  ) {
    if Self.leavesSettings(route) { settings.close() }
    apply(route, in: session, openSettingsAt: .settingsPage(settings))
  }
}

/// A server window's Settings: the page over the window's content, left when the window goes
/// somewhere else, and reached from Omnigent > Settings and the menu bar through the desktop.
struct WindowSettingsHost<Page: View>: ViewModifier {
  let settings: SettingsNavigator
  @Binding var selection: SidebarDestination?
  let window: UUID
  let desktop: DesktopController
  let page: Page

  func body(content: Content) -> some View {
    content
      .settingsPage(settings) { page }
      .leavesSettings(settings, onChangeOf: $selection)
      .serverWindowSettings(
        window, desktop: desktop, page: ServerWindowRoot.windowPage(settings))
  }
}

extension ServerWindowRoot {
  /// The page of a link to one automation, workflow or Canvas board, asked to show it.
  static func itemPage(_ route: OmnigentDesktop.DeepLinkRoute, in session: ServerSession)
    -> SidebarDestination?
  {
    switch route {
    case .automation(let id): return automation(id, in: session)
    case .workflow(let id): return workflow(id, in: session)
    case .canvas(let board, let sessionID):
      session.connection.canvas?.requestedLink = CanvasLinkRequest(
        board: board, sessionID: sessionID)
      return .canvas
    default: return nil
    }
  }
}
