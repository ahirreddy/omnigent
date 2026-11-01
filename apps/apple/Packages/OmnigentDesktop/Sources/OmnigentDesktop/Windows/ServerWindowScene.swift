import AppKit
public import SwiftUI

/// Window sizes, matching the Electron shell.
public enum ServerWindowMetrics {
  /// Size of a first window with no saved frame.
  public static let defaultSize = CGSize(width: 1280, height: 860)
  /// Smallest size at which the connect screen and the three-column layout still fit.
  public static let minimumSize = CGSize(width: 720, height: 600)
  /// The `NSWindow` frame autosave name for server windows.
  public static let frameAutosaveName = "OmnigentServerWindow"
}

/// One window per server binding: `WindowGroup(for: ServerWindowID.self)` with the desktop
/// defaults (size, minimum size, unified toolbar, restoration).
///
/// SwiftUI restores open windows and their values when the user keeps windows on quit.
/// `content` should apply `View.serverWindow(_:desktop:...)` so routing, focus and badges work.
public struct ServerWindowScene<Content: View>: Scene {
  private let title: String
  private let defaultServerURL: () -> URL?
  private let content: (Binding<ServerWindowID>) -> Content

  /// Creates the scene.
  /// - Parameters:
  ///   - title: Default window title; content can override it with `navigationTitle`.
  ///   - defaultServerURL: The server for windows the system opens (launch, Dock click).
  ///   - content: The window's root view.
  public init(
    _ title: String = "Omnigent",
    defaultServerURL: @escaping () -> URL?,
    @ViewBuilder content: @escaping (Binding<ServerWindowID>) -> Content
  ) {
    self.title = title
    self.defaultServerURL = defaultServerURL
    self.content = content
  }

  /// The window group.
  public var body: some Scene {
    WindowGroup(title, for: ServerWindowID.self) { id in
      content(id)
        .frame(
          minWidth: ServerWindowMetrics.minimumSize.width,
          minHeight: ServerWindowMetrics.minimumSize.height)
    } defaultValue: {
      ServerWindowID.newWindow(serverURL: defaultServerURL())
    }
    .defaultSize(ServerWindowMetrics.defaultSize)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified)
    // Without this SwiftUI opens an extra window for every `omnigent://` URL, even when the app
    // delegate implements `application(_:open:)`. URLs go to `DesktopRouter` instead.
    .handlesExternalEvents(matching: [])
  }
}

extension View {
  /// Connects a server window to the desktop shell: registers it for deep-link routing, badge
  /// totals and notification suppression, publishes its menu actions, and applies routes.
  /// - Parameters:
  ///   - id: The scene's binding.
  ///   - desktop: The shell services.
  ///   - isReady: Whether the window is connected and can navigate.
  ///   - viewedSessionID: The conversation it shows, which suppresses its notifications.
  ///   - unreadCount: Its server's unread count for the Dock badge.
  ///   - actions: Its menu actions.
  ///   - onRoute: Navigates to a deep link or notification route once `isReady`.
  /// - Returns: The configured view.
  public func serverWindow(
    _ id: Binding<ServerWindowID>,
    desktop: DesktopController,
    isReady: Bool,
    viewedSessionID: String? = nil,
    unreadCount: Int = 0,
    actions: ServerWindowActions = ServerWindowActions(),
    onRoute: @escaping (DeepLinkRoute) -> Void
  ) -> some View {
    modifier(
      ServerWindowModifier(
        id: id, desktop: desktop, isReady: isReady, viewedSessionID: viewedSessionID,
        unreadCount: unreadCount, actions: actions, onRoute: onRoute))
  }

  /// Persists the window frame under an `NSWindow` autosave name, so the next window opens where
  /// the last one was even when the user has macOS close windows on quit (which skips SwiftUI
  /// restoration). AppKit lets one open window hold a name; later windows cascade normally.
  /// - Parameter name: The autosave name.
  /// - Returns: The configured view.
  public func windowFrameAutosave(_ name: String = ServerWindowMetrics.frameAutosaveName)
    -> some View
  {
    background(WindowFrameAutosave(name: name))
  }
}

struct ServerWindowModifier: ViewModifier {
  @Binding var id: ServerWindowID
  let desktop: DesktopController
  let isReady: Bool
  let viewedSessionID: String?
  let unreadCount: Int
  let actions: ServerWindowActions
  let onRoute: (DeepLinkRoute) -> Void

  @Environment(\.openWindow) private var openWindow
  @Environment(\.appearsActive) private var appearsActive

  func body(content: Content) -> some View {
    let registry = desktop.registry
    let pending = registry.pendingRoute(for: id.instance)
    content
      .focusedSceneValue(\.serverWindow, FocusedServerWindow(id: id, actions: actions))
      .onAppear {
        report()
        let openWindow = openWindow
        desktop.router.attachWindowOpener { openWindow(value: $0) }
      }
      .onDisappear { registry.remove(id.instance) }
      .onChange(of: id) { report() }
      .onChange(of: isReady) { report() }
      .onChange(of: viewedSessionID) { report() }
      .onChange(of: unreadCount) { report() }
      .onChange(of: appearsActive, initial: true) {
        registry.setKey(id.instance, isKey: appearsActive)
      }
      .onChange(of: pending, initial: true) { applyPendingRoute() }
  }

  private func report() {
    desktop.registry.update(
      id, isReady: isReady, viewedSessionID: viewedSessionID, unreadCount: unreadCount)
    applyPendingRoute()
  }

  private func applyPendingRoute() {
    guard let route = desktop.registry.takePendingRoute(for: id.instance) else { return }
    onRoute(route)
  }
}

struct WindowFrameAutosave: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> AutosaveView {
    AutosaveView(name: name)
  }

  func updateNSView(_ view: AutosaveView, context: Context) {}

  final class AutosaveView: NSView {
    private let name: String

    init(name: String) {
      self.name = name
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // `NSView.window` is `unowned(unsafe)`; it is read once while AppKit attaches the view.
      guard let window = unsafe self.window, window.frameAutosaveName != name else { return }
      // Returns false when another open window holds the name; this window then keeps the
      // frame SwiftUI chose.
      guard window.setFrameAutosaveName(name) else { return }
      // Returns false when nothing is saved yet, leaving the default size.
      _ = window.setFrameUsingName(name)
    }
  }
}
