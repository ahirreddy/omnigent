public import SwiftUI

/// What a server window tells the desktop shell about itself.
public struct ServerWindowStatus {
  /// Whether the window is connected and can navigate.
  public var isReady: Bool
  /// The conversation it shows, which suppresses its notifications.
  public var viewedSessionID: String?
  /// Its server's unread count for the Dock badge.
  public var unreadCount: Int
  /// Its menu actions.
  public var actions: ServerWindowActions

  /// Creates a status.
  /// - Parameters:
  ///   - isReady: Whether the window is connected and can navigate.
  ///   - viewedSessionID: The conversation it shows.
  ///   - unreadCount: Its server's unread count.
  ///   - actions: Its menu actions.
  public init(
    isReady: Bool, viewedSessionID: String? = nil, unreadCount: Int = 0,
    actions: ServerWindowActions = ServerWindowActions()
  ) {
    self.isReady = isReady
    self.viewedSessionID = viewedSessionID
    self.unreadCount = unreadCount
    self.actions = actions
  }
}

extension View {
  /// Connects a server window to the desktop shell, reading what the window shows where it is
  /// reported: a session, a tab or a badge that changes then renders this modifier and not the
  /// window's root.
  /// - Parameters:
  ///   - id: The scene's binding.
  ///   - desktop: The shell services.
  ///   - selection: What the window shows. The root passes it on without reading it.
  ///   - status: The window's status while it shows a selection, read in the modifier's body.
  ///   - onRoute: Navigates to a deep link or notification route once the window is ready.
  /// - Returns: The configured view.
  public func serverWindow<Selection>(
    _ id: Binding<ServerWindowID>, desktop: DesktopController, selection: Binding<Selection>,
    status: @escaping (Selection) -> ServerWindowStatus,
    onRoute: @escaping (DeepLinkRoute) -> Void
  ) -> some View {
    modifier(
      ShownServerWindow(
        id: id, desktop: desktop, selection: selection, status: status, onRoute: onRoute))
  }
}

struct ShownServerWindow<Selection>: ViewModifier {
  @Binding var id: ServerWindowID
  let desktop: DesktopController
  @Binding var selection: Selection
  let status: (Selection) -> ServerWindowStatus
  let onRoute: (DeepLinkRoute) -> Void

  func body(content: Content) -> some View {
    let status = status(selection)
    return content.serverWindow(
      $id, desktop: desktop, isReady: status.isReady, viewedSessionID: status.viewedSessionID,
      unreadCount: status.unreadCount, actions: status.actions, onRoute: onRoute)
  }
}
