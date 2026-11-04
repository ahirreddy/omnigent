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
  private let tabContext: TabWindowContext
  private let serverSwitching: ServerSwitching?

  /// Creates the root.
  /// - Parameters:
  ///   - session: The connection and its sign-in.
  ///   - selection: What the connected app shows; kept by the host for deep links.
  ///   - isWindowFocused: Whether the window is key.
  ///   - openInNewWindow: Opens a session in a new window, where the platform has windows.
  ///   - tabContext: Where the window's tabs are saved, the browser, and tear-off.
  ///   - serverSwitching: Other servers the sidebar's switcher offers.
  public init(
    session: ServerSession, selection: Binding<SidebarDestination?>,
    isWindowFocused: Bool = true, openInNewWindow: (@MainActor (String) -> Void)? = nil,
    tabContext: TabWindowContext = TabWindowContext(), serverSwitching: ServerSwitching? = nil
  ) {
    self.session = session
    _selection = selection
    self.isWindowFocused = isWindowFocused
    self.openInNewWindow = openInNewWindow
    self.tabContext = tabContext
    self.serverSwitching = serverSwitching
  }

  /// Sign-in until connected, then the connected app.
  public var body: some View {
    if session.isSignedIn {
      ConnectedServerView(
        session: session, selection: $selection, isWindowFocused: isWindowFocused,
        openInNewWindow: openInNewWindow, tabContext: tabContext,
        serverSwitching: serverSwitching)
    } else {
      AuthFlowView(
        state: session.signIn.state, actions: session.signIn.actions, validator: .app
      )
      // The flow's one primary action stays the brand pink; system controls elsewhere use the
      // system tint.
      .tint(ThemeColor.accent)
      // A container, so the form's own identifiers (auth.username, auth.sign-in) survive.
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("auth.flow")
    }
  }
}
