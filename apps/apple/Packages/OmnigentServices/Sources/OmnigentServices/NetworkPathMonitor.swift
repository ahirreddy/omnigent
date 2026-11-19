import Foundation
import Network

/// One reading of the device's route to the network.
public struct NetworkPath: Equatable, Sendable {
  /// A route exists.
  public var isSatisfied: Bool
  /// The interfaces it uses, by name (`en0`, `utun3`); another set is another network or a VPN.
  public var interfaces: [String]

  /// Creates a reading.
  /// - Parameters:
  ///   - isSatisfied: Whether a route exists.
  ///   - interfaces: The interfaces it uses.
  public init(isSatisfied: Bool, interfaces: [String]) {
    self.isSatisfied = isSatisfied
    self.interfaces = interfaces
  }

  /// Whether this reading, after `previous`, is a network coming back or a new one (Wi-Fi to
  /// Ethernet, a VPN up or down): connections should try the server again at once.
  /// - Parameter previous: The reading before, `nil` for the first.
  /// - Returns: Whether to try again.
  public func isReturn(after previous: Self?) -> Bool {
    guard isSatisfied, let previous else { return false }
    return !previous.isSatisfied || previous.interfaces != interfaces
  }
}

/// The device's network route as it changes (`NWPathMonitor`), so a connection waiting out a
/// backoff tries again as soon as the network or VPN is back.
public enum NetworkPathMonitor {
  /// The current reading, then one per change. The monitor stops when the stream's consumer does.
  /// - Returns: The readings; only the newest waits while the consumer is busy.
  public static func paths() -> AsyncStream<NetworkPath> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let monitor = PathMonitor()
      monitor.monitor.pathUpdateHandler = { path in
        continuation.yield(
          NetworkPath(
            isSatisfied: path.status == .satisfied,
            interfaces: path.availableInterfaces.map(\.name)))
      }
      continuation.onTermination = { _ in monitor.monitor.cancel() }
      monitor.monitor.start(queue: DispatchQueue(label: "ai.omnigent.network-path"))
    }
  }
}

/// Owns one `NWPathMonitor`, which is not `Sendable`: it is configured before it starts, and
/// afterwards only its thread-safe `cancel` is called.
private final class PathMonitor: @unchecked Sendable {
  let monitor = NWPathMonitor()
}
