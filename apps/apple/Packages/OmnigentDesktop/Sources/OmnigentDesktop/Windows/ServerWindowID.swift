public import Foundation

/// The value a server window presents: `WindowGroup(for: ServerWindowID.self)`.
///
/// Each window is bound to at most one server. `instance` keeps two windows on the same server
/// distinct, because `openWindow(value:)` brings an existing window with an equal value to the
/// front instead of opening another. SwiftUI persists the value for window restoration, so it
/// holds only the instance and server, never credentials or navigation state.
nonisolated public struct ServerWindowID: Hashable, Codable, Sendable, Identifiable {
  /// Stable identity of the window across server changes and relaunches.
  public var instance: UUID
  /// The full server URL including any workspace mount, or `nil` for the connect screen.
  public var serverURL: URL?

  /// Creates a window value.
  /// - Parameters:
  ///   - instance: The window identity.
  ///   - serverURL: The server, or `nil` for the connect screen.
  public init(instance: UUID = UUID(), serverURL: URL?) {
    self.instance = instance
    self.serverURL = serverURL
  }

  /// A new window on `serverURL`, or on the connect screen when `nil`.
  /// - Parameter serverURL: The server.
  /// - Returns: A value with a fresh instance.
  public static func newWindow(serverURL: URL?) -> Self {
    Self(serverURL: serverURL)
  }

  /// The window's identity for `Identifiable`; unchanged when the server changes.
  public var id: UUID { instance }

  /// The bound server's origin, or `nil` on the connect screen.
  /// - Throws: `ServerOriginError` when `serverURL` is not a valid http(s) URL.
  public var origin: ServerOrigin? {
    get throws(ServerOriginError) {
      guard let serverURL else { return nil }
      return try ServerOrigin(url: serverURL)
    }
  }

  /// The same window bound to another server.
  /// - Parameter serverURL: The new server, or `nil` to return to the connect screen.
  /// - Returns: A value with the same instance.
  public func rebound(to serverURL: URL?) -> Self {
    Self(instance: instance, serverURL: serverURL)
  }
}
