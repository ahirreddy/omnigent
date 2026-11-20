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
  /// The Harnesses pane of `url`'s settings, on a host and harness, as the web's
  /// `/settings/harnesses/<harness>?host=<host>`.
  case harness(url: String?, focus: HarnessSettingsFocus)
  /// Settings search, with the keyboard in its field (the palette's Search Settings…).
  case search
}

/// The host and harness the Harnesses pane opens to. Each request is distinct, so asking again
/// shows them again.
public struct HarnessSettingsFocus: Hashable, Sendable {
  /// The harness whose details open; `nil` shows the harness list.
  public let harness: String?
  /// The host shown; `nil` keeps the pane's.
  public let hostID: String?
  let id: UUID

  /// Creates a focus.
  /// - Parameters:
  ///   - harness: The harness to open.
  ///   - hostID: The host to show.
  public init(harness: String?, hostID: String?) {
    self.harness = harness
    self.hostID = hostID
    id = UUID()
  }
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
  /// The host and harness the Harnesses pane shows next; it clears it once shown.
  public private(set) var harnessFocus: HarnessSettingsFocus?
  /// Whether a Mac window shows its Settings page over its content. iPhone and iPad present
  /// their Settings screen themselves.
  public private(set) var isPresented = false
  /// Settings search takes the keyboard; its field clears this once it has.
  public var focusesSearch = false
  /// The panes the shown server's settings offer, once they have shown (``hasServerPanes``).
  public private(set) var serverPanes: [ServerSettingsPane] = []
  /// Whether a server's settings have shown and said which panes they offer.
  public private(set) var hasServerPanes = false

  /// Records the panes the shown server's settings offer, for Settings search.
  /// - Parameter panes: The panes.
  public func recordServerPanes(_ panes: [ServerSettingsPane]) {
    if serverPanes != panes { serverPanes = panes }
    if !hasServerPanes { hasServerPanes = true }
  }

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
    case .harness(let url, let focus):
      select(Self.serversTab)
      serverRequest = ServerSettingsRequest(url: url, pane: .harnesses)
      harnessFocus = focus
    case .search:
      focusesSearch = true
    }
  }

  /// Asks the Harnesses pane for a host and harness, without moving Settings.
  /// - Parameter focus: The host and harness.
  func focusHarness(_ focus: HarnessSettingsFocus) {
    harnessFocus = focus
  }

  /// Takes the pending host and harness, clearing them.
  /// - Returns: The focus, if one is pending.
  public func takeHarnessFocus() -> HarnessSettingsFocus? {
    guard let focus = harnessFocus else { return nil }
    harnessFocus = nil
    return focus
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
  }
#endif
