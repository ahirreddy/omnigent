import Foundation
public import OmnigentCoreFFI

/// Where discovery and sign-in stand, read from ``ConnectionStore/state`` and
/// ``ConnectionStore/phase``.
extension ConnectionStore {
  /// Whether discovery is in flight.
  public var isLoading: Bool {
    if case .loading = state { return true }
    return false
  }

  /// Whether discovery succeeded and the server is usable.
  public var isConnected: Bool { discovery != nil }

  /// Whether the core is connected and signed in.
  public var isSignedIn: Bool {
    if case .connected = phase { return true }
    return false
  }

  /// The server the core is connected to.
  public var connectedServer: ConnectedServer? {
    if case .connected(let server) = phase { return server }
    return nil
  }

  /// The discovered server, when connected.
  public var discovery: ServerDiscovery? {
    if case .connected(let discovery) = state { return discovery }
    return nil
  }

  /// The failure message, when discovery failed.
  public var errorMessage: String? {
    if case .failed(_, let message) = state { return message }
    return nil
  }
}
