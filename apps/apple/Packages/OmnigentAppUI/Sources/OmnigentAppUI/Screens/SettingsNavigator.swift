public import Foundation
public import Observation
public import OmnigentUIComponents
public import SwiftUI

/// A place in the Settings window: a tab, or one server's settings pane.
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
  let id = UUID()
}

/// Which Settings tab shows, and the server pane to show next, shared by the Settings window and
/// the windows that open it.
@MainActor
@Observable
public final class SettingsNavigator {
  /// The app's navigator.
  public static let shared = SettingsNavigator()

  /// General (the built-in tab's title).
  public static let generalTab = "General"
  /// Appearance.
  public static let appearanceTab = "Appearance"
  /// Terminal.
  public static let terminalTab = "Terminal"
  /// Each signed-in server's settings.
  public static let serversTab = "Servers"

  /// The shown tab's id.
  public var tab = SettingsNavigator.generalTab
  /// The server pane the Servers tab shows next; it clears it once shown.
  public private(set) var serverRequest: ServerSettingsRequest?

  /// Creates a navigator on General.
  public init() {}

  /// Moves the Settings window's state to `destination`; the caller opens the window.
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

/// Opens the Settings window at a destination. The app sets it where it has a Settings window.
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
  /// Opens the Settings window at a destination; `nil` where there is no Settings window.
  @Entry public var openSettingsAt: OpenSettingsDestinationAction?
}

#if os(macOS)
  extension OpenSettingsDestinationAction {
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
