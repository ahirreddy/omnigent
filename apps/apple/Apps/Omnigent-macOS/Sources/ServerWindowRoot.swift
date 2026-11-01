import OSLog
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentUI
import SwiftUI

/// One server window: its own `ConnectionStore`, bound to the server in its `ServerWindowID`.
///
/// The window is ready (deep links navigate in place, notifications are suppressed while it
/// shows a session) only while its store is connected to exactly the server the window is bound
/// to, so rebinding the window makes it not ready in the same update.
struct ServerWindowRoot: View {
  @Binding var id: ServerWindowID
  let services: AppServices

  @State private var store = ConnectionStore()
  /// The server `store` last connected to on this window's behalf.
  @State private var connectedURL: URL?
  @State private var route: DeepLinkRoute = .home
  @Environment(\.openWindow) private var openWindow

  private var desktop: DesktopController { services.desktop }

  private var isReady: Bool {
    guard let serverURL = id.serverURL else { return false }
    return store.isConnected && connectedURL == serverURL
  }

  private var viewedSessionID: String? {
    guard isReady, case .conversation(let sessionID) = route else { return nil }
    return sessionID
  }

  var body: some View {
    RootView(sessionID: viewedSessionID)
      .environment(store)
      .environment(\.serverConnectAction, ServerConnectAction { connect(typed: $0) })
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Browser", systemImage: "globe", action: openBrowser)
            .disabled(id.serverURL == nil)
            .help("Open this server in the browser window (Option-Command-B)")
            .accessibilityIdentifier("toolbar.browser")
        }
      }
      .serverWindow(
        $id, desktop: desktop, isReady: isReady, viewedSessionID: viewedSessionID,
        unreadCount: 0, actions: actions, onRoute: { route = $0 }
      )
      .windowFrameAutosave()
      .task(id: id.serverURL) { await discoverBoundServer(force: false) }
      .task { await reconnectOnSystemTriggers() }
  }

  private var title: String {
    if let discovery = store.discovery, isReady {
      return discovery.serverName ?? id.serverURL?.host(percentEncoded: false) ?? "Omnigent"
    }
    return id.serverURL?.host(percentEncoded: false) ?? "Omnigent"
  }

  private var actions: ServerWindowActions {
    ServerWindowActions(
      changeServer: id.serverURL == nil ? nil : { id = id.rebound(to: nil) },
      reconnect: id.serverURL == nil ? nil : { Task { await discoverBoundServer(force: true) } })
  }

  /// Connect from the form: the core validates and normalizes what was typed, and on success
  /// the window is rebound to the server the core resolved.
  private func connect(typed text: String) {
    Task {
      await store.discover(serverURL: text)
      guard let discovery = store.discovery else { return }
      guard let serverURL = URL(string: discovery.baseUrl) else {
        services.logger.error(
          "The core returned a base URL Foundation rejects: \(discovery.baseUrl, privacy: .public)")
        return
      }
      route = .home
      connectedURL = serverURL
      id = id.rebound(to: serverURL)
      await services.didConnect(to: serverURL)
    }
  }

  /// Discovers the window's server. Runs when the binding changes and on Reconnect.
  private func discoverBoundServer(force: Bool) async {
    guard let serverURL = id.serverURL else {
      connectedURL = nil
      route = .home
      store.reset()
      return
    }
    if !force, connectedURL == serverURL, store.isConnected { return }
    connectedURL = nil
    await store.discover(serverURL: serverURL.absoluteString)
    guard !Task.isCancelled, id.serverURL == serverURL else { return }
    if store.isConnected {
      connectedURL = serverURL
      await services.didConnect(to: serverURL)
    } else if let message = store.errorMessage {
      services.logger.notice(
        "Could not connect to \(serverURL.absoluteString, privacy: .public): \(message, privacy: .public)"
      )
    }
  }

  /// Wake, unlock and session switches restart discovery, so a server that came back with the
  /// VPN reconnects within seconds.
  private func reconnectOnSystemTriggers() async {
    let monitor = desktop.makeReconnectMonitor()
    for await trigger in monitor.triggers {
      guard id.serverURL != nil else { continue }
      services.logger.info("Reconnecting after \(String(describing: trigger), privacy: .public)")
      await discoverBoundServer(force: true)
    }
    monitor.stop()
  }

  private func openBrowser() {
    guard let serverURL = id.serverURL else { return }
    openWindow(id: BrowserWindow.id, value: serverURL)
  }
}
