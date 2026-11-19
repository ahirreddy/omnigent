import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import SwiftUI

/// Tries the server again without the user asking: at once when the network or VPN comes back,
/// and on a widening schedule while nothing else will (offline with the saved copy, a connect
/// that could not reach the server, or a live link that gave up). The core retries a dropped
/// link itself; this covers what it leaves to the app.
struct AutomaticReconnect: ViewModifier {
  let session: ServerSession
  /// The network's readings; a test passes its own.
  var paths: @MainActor () -> AsyncStream<NetworkPath> = { NetworkPathMonitor.paths() }

  func body(content: Content) -> some View {
    content
      .task { await reconnectWhenTheNetworkReturns() }
      .task(id: Self.waitsForTheApp(session.connection)) {
        guard Self.waitsForTheApp(session.connection) else { return }
        await retryWhileUnreachable()
      }
  }

  /// Whether the connection stays down until the app tries again: the core retries only a link
  /// that is reconnecting.
  static func waitsForTheApp(_ connection: ConnectionStore) -> Bool {
    switch connection.health.reachability {
    case .offline, .unreachable: true
    case .online, .reconnecting: false
    }
  }

  /// The wait before the app's `attempt`-th try (from 1): 2, 4, 8 and 16 seconds, then 30.
  static func delay(attempt: Int) -> Duration {
    .seconds(min(30, 1 << min(max(attempt, 1), 5)))
  }

  /// Whether a connect is already on its way, which a new one would only restart.
  static func isConnecting(_ connection: ConnectionStore) -> Bool {
    switch connection.phase {
    case .discovering, .connecting, .signingIn, .awaitingBrowserLogin: true
    case .disconnected, .signInRequired, .connected, .failed: false
    }
  }

  private func retryWhileUnreachable() async {
    var attempt = 0
    while !Task.isCancelled {
      attempt += 1
      do {
        try await Task.sleep(for: Self.delay(attempt: attempt))
      } catch {
        return  // Cancelled: the server came back or the view left.
      }
      guard Self.waitsForTheApp(session.connection) else { return }
      if !Self.isConnecting(session.connection) { session.reconnect() }
    }
  }

  private func reconnectWhenTheNetworkReturns() async {
    var previous: NetworkPath?
    for await path in paths() {
      defer { previous = path }
      guard path.isReturn(after: previous), session.showsSessions else { continue }
      // A link that looks live may have died with the old network; foreground replaces the
      // ones silent long enough and redials the ones waiting.
      if !Self.isConnecting(session.connection) { session.reconnect() }
    }
  }
}

extension View {
  /// Tries `session`'s server again when the network returns and while it cannot be reached.
  func reconnectsAutomatically(_ session: ServerSession) -> some View {
    modifier(AutomaticReconnect(session: session))
  }
}
