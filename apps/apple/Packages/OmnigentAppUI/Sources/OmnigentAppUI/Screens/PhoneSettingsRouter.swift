import Foundation
import Observation
import OmnigentUIComponents
import SwiftUI

/// A page of the iPhone and iPad Settings screen that isn't a server pane: the Mac Settings
/// window's General, Appearance and Terminal tabs, plus Notifications.
enum PhoneSettingsPage: String, Hashable, CaseIterable, Identifiable {
  case general
  case appearance
  case notifications
  case terminal

  var id: Self { self }

  /// The page for a Settings tab id (``SettingsNavigator/generalTab`` and the others), if the
  /// screen has one.
  init?(tab: String) {
    switch tab {
    case SettingsNavigator.generalTab: self = .general
    case SettingsNavigator.appearanceTab: self = .appearance
    case SettingsNavigator.notificationsTab: self = .notifications
    case SettingsNavigator.terminalTab: self = .terminal
    default: return nil
    }
  }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .notifications: "Notifications"
    case .terminal: "Terminal"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintpalette"
    case .notifications: "bell.badge"
    case .terminal: "apple.terminal"
    }
  }
}

/// Where the iPhone and iPad Settings screen opens for a ``SettingsDestination``: whose server
/// panes it lists, and the page it pushes on its root list.
struct PhoneSettingsRoute: Equatable {
  /// A page pushed on the root list.
  enum Page: Equatable {
    case app(PhoneSettingsPage)
    case server(ServerSettingsPane)

    /// The page a debug launch names with `-OmnigentOpenSettings` (`general`, `archived`...),
    /// for screenshots; `root` and unknown names are `nil`.
    init?(launchName name: String) {
      if let page = PhoneSettingsPage(rawValue: name) {
        self = .app(page)
      } else if let pane = ServerSettingsPane(rawValue: name) {
        self = .server(pane)
      } else {
        return nil
      }
    }
  }

  /// The server whose panes show: the destination's, else the scene's.
  let serverURL: String?
  /// The pushed page, or `nil` for the root list. General opens the root, where its row is
  /// first, as the palette's "Go to Settings" means the whole screen.
  let page: Page?

  init(_ destination: SettingsDestination, sceneServer: String?) {
    switch destination {
    case .tab(let id):
      serverURL = sceneServer
      page = PhoneSettingsPage(tab: id).flatMap { $0 == .general ? nil : .app($0) }
    case .server(let url, let pane):
      serverURL = url ?? sceneServer
      page = pane.map(Page.server)
    }
  }
}

/// One scene's Settings screen: whether it shows, its navigation path, and the actions the
/// scene's menus open it with. The actions are made once, so they stay equal across updates.
@MainActor
@Observable
final class PhoneSettingsRouter {
  /// The screen is presented.
  var isPresented = false
  /// The pushed pages: ``PhoneSettingsPage`` and ``ServerSettingsPane`` values.
  var path = NavigationPath()
  /// Picks the server the screen's panes show.
  let navigator = SettingsNavigator()
  /// The scene's signed-in server, which the screen shows unless a destination names another.
  @ObservationIgnored var sceneServer: @MainActor () -> String? = { nil }
  /// Opens the screen at a destination (``EnvironmentValues/openSettingsAt``).
  @ObservationIgnored private(set) var openAt: OpenSettingsDestinationAction?
  /// The server menu's Settings item.
  @ObservationIgnored let screen = SettingsScreenPresenter()
  /// Appearance, from the session title menu.
  @ObservationIgnored let appearance = AppearanceSettingsPresenter()
  /// Notifications.
  @ObservationIgnored let notifications = NotificationSettingsPresenter()

  init() {
    openAt = OpenSettingsDestinationAction { [weak self] in self?.open($0) }
    screen.open = { [weak self] in self?.open(.tab(SettingsNavigator.generalTab)) }
    appearance.open = { [weak self] in self?.open(.tab(SettingsNavigator.appearanceTab)) }
    notifications.open = { [weak self] in self?.open(.tab(SettingsNavigator.notificationsTab)) }
  }

  /// Shows the screen at `destination`, replacing whatever page was pushed.
  /// - Parameter destination: The page or server pane.
  func open(_ destination: SettingsDestination) {
    let route = PhoneSettingsRoute(destination, sceneServer: sceneServer())
    show(route.page, server: route.serverURL)
  }

  /// Shows the screen on `server`'s panes at `page` (the root list when `nil`).
  /// - Parameters:
  ///   - page: The pushed page.
  ///   - server: The server whose panes show.
  func show(_ page: PhoneSettingsRoute.Page?, server: String?) {
    navigator.show(.server(url: server, pane: nil))
    if isPresented {
      path = Self.path(page)
    } else {
      // A page pushed with the presentation keeps the state it was pushed with: push it once
      // the root list is on screen (``screenAppeared()``).
      path = NavigationPath()
      pendingPage = page
      isPresented = true
    }
  }

  /// The root list is on screen: pushes the page the screen was opened at.
  func screenAppeared() {
    guard let page = pendingPage else { return }
    pendingPage = nil
    path = Self.path(page)
  }

  @ObservationIgnored private var pendingPage: PhoneSettingsRoute.Page?

  private static func path(_ page: PhoneSettingsRoute.Page?) -> NavigationPath {
    var path = NavigationPath()
    switch page {
    case .app(let page): path.append(page)
    case .server(let pane): path.append(pane)
    case nil: break
    }
    return path
  }
}
