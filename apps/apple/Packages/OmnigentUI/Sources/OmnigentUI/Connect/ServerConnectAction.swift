public import SwiftUI

/// Lets a host take over what the connect form's Connect button does.
///
/// The macOS app binds each window to one server, so it handles Connect itself: it runs
/// discovery and rebinds the window. Without a host action the form discovers on its own and
/// connects to the stored server when it first appears (the iOS behavior).
public struct ServerConnectAction {
  private let handler: (String) -> Void

  /// Creates the action.
  /// - Parameter handler: Receives the server URL exactly as typed.
  public init(_ handler: @escaping (String) -> Void) {
    self.handler = handler
  }

  /// Connects to `serverURL`.
  /// - Parameter serverURL: The server URL as typed.
  public func callAsFunction(_ serverURL: String) {
    handler(serverURL)
  }
}

extension EnvironmentValues {
  /// The host's connect action, if it handles Connect itself.
  @Entry public var serverConnectAction: ServerConnectAction?
}
