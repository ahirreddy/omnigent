public import Foundation
public import Observation
public import OmnigentUIComponents
public import SwiftUI

/// A place in Settings: a tab (a category of the Mac's page), or one server's settings pane.
public enum SettingsDestination: Hashable, Sendable {
  /// A tab, by id (its title, for example ``SettingsNavigator/generalTab``).
  case tab(String)
  /// The Servers tab on `url`'s settings (the first signed-in server when `nil`), at `pane`
  /// (the server's first pane when `nil` or not offered).
  case server(url: String?, pane: ServerSettingsPane?)
}

/// A server and pane the Servers tab shows next. Each request is distinct, so asking for the
/// same server twice still moves the tab back to it.
public struct ServerSettingsRequest: Hashable, Sendable {
  /// The server, or `nil` for the first one.
  public let url: String?
  /// The pane, or `nil` for the first one.
  public let pane: ServerSettingsPane?
  let id: UUID

  init(url: String?, pane: ServerSettingsPane?) {
    self.url = url
    self.pane = pane
    id = UUID()
  }
}

/// Which Settings tab shows, and the server pane to show next. Each Mac window has its own,
/// which also says whether the window shows its Settings page; iPhone and iPad have one for
/// their Settings screen.
@MainActor
@Observable
public final class SettingsNavigator {
  /// The Settings window's navigator.
  public static let shared = SettingsNavigator()

  /// General (the built-in tab's title).
  public static let generalTab = "General"
  /// Appearance.
  public static let appearanceTab = "Appearance"
  /// Terminal.
  public static let terminalTab = "Terminal"
  /// Notifications (iPhone and iPad; the Mac notifies through its own system settings).
  public static let notificationsTab = "Notifications"
  /// Each signed-in server's settings.
  public static let serversTab = "Servers"

  /// The shown tab's id.
  public var tab = SettingsNavigator.generalTab
  /// The server pane the Servers tab shows next; it clears it once shown.
  public private(set) var serverRequest: ServerSettingsRequest?
  /// Whether a Mac window shows its Settings page over its content. iPhone and iPad present
  /// their Settings screen themselves.
  public private(set) var isPresented = false

  /// Creates a navigator on General.
  public init() {}

  /// Moves Settings to `destination`; the caller shows it.
  /// - Parameter destination: The tab or server pane.
  public func show(_ destination: SettingsDestination) {
    switch destination {
    case .tab(let id):
      select(id)
    case .server(let url, let pane):
      select(Self.serversTab)
      serverRequest = ServerSettingsRequest(url: url, pane: pane)
    }
  }

  /// Takes the pending server request, clearing it.
  /// - Returns: The request, if one is pending.
  public func takeServerRequest() -> ServerSettingsRequest? {
    guard let request = serverRequest else { return nil }
    serverRequest = nil
    return request
  }

  private func select(_ id: String) {
    if tab != id { tab = id }
  }
}

#if os(macOS)
  extension SettingsNavigator {
    /// Shows the window's Settings page, at `destination` or where it last was.
    /// - Parameter destination: The tab or server pane to show, if any.
    public func open(_ destination: SettingsDestination? = nil) {
      if let destination { show(destination) }
      if !isPresented { isPresented = true }
    }

    /// Goes back to the window's content.
    public func close() {
      if isPresented { isPresented = false }
    }
  }
#endif

/// Opens Settings at a destination. The app sets it where it has Settings to show.
public struct OpenSettingsDestinationAction {
  private let open: @MainActor (SettingsDestination) -> Void

  /// Creates the action.
  /// - Parameter open: Moves to the destination and shows the window.
  public init(_ open: @escaping @MainActor (SettingsDestination) -> Void) {
    self.open = open
  }

  /// Opens Settings at `destination`.
  @MainActor public func callAsFunction(_ destination: SettingsDestination) {
    open(destination)
  }
}

extension EnvironmentValues {
  /// Opens Settings at a destination; `nil` where there is no Settings to show.
  @Entry public var openSettingsAt: OpenSettingsDestinationAction?
}

#if os(macOS)
  extension OpenSettingsDestinationAction {
    /// Shows a window's Settings page at the destination.
    /// - Parameter navigator: The window's navigator.
    /// - Returns: The action.
    @MainActor public static func settingsPage(_ navigator: SettingsNavigator) -> Self {
      Self { destination in navigator.open(destination) }
    }

    /// Moves `navigator` to the destination, then opens (or fronts) the Settings scene.
    /// - Parameters:
    ///   - navigator: The Settings window's navigator.
    ///   - openSettings: The scene's `openSettings` action.
    /// - Returns: The action.
    @MainActor public static func settingsWindow(
      _ navigator: SettingsNavigator = .shared, openSettings: OpenSettingsAction
    ) -> Self {
      Self { destination in
        navigator.show(destination)
        openSettings()
      }
    }
  }
#endif
