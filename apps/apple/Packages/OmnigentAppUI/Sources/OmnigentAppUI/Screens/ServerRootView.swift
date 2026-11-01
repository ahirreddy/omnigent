import OmnigentAuthUI
import OmnigentStores
public import OmnigentUIComponents
public import SwiftUI

/// What a window or scene shows for its ``ServerSession``: the sign-in flow until the core is
/// connected, then the connected app.
public struct ServerRootView: View {
  private let session: ServerSession
  @Binding private var selection: SidebarDestination?
  private let isWindowFocused: Bool
  private let openInNewWindow: (@MainActor (String) -> Void)?

  /// Creates the root.
  /// - Parameters:
  ///   - session: The connection and its sign-in.
  ///   - selection: What the connected app shows; kept by the host for deep links.
  ///   - isWindowFocused: Whether the window is key.
  ///   - openInNewWindow: Opens a session in a new window, where the platform has windows.
  public init(
    session: ServerSession, selection: Binding<SidebarDestination?>,
    isWindowFocused: Bool = true, openInNewWindow: (@MainActor (String) -> Void)? = nil
  ) {
    self.session = session
    _selection = selection
    self.isWindowFocused = isWindowFocused
    self.openInNewWindow = openInNewWindow
  }

  public var body: some View {
    if session.isSignedIn {
      ConnectedServerView(
        session: session, selection: $selection, isWindowFocused: isWindowFocused,
        openInNewWindow: openInNewWindow)
    } else {
      AuthFlowView(
        state: session.signIn.state, actions: session.signIn.actions, validator: .app)
        .accessibilityIdentifier("auth.flow")
    }
  }
}
