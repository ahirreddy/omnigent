import Network
import Synchronization

/// Failures of the test servers themselves.
public enum TestServerError: Error, Sendable {
  /// The listener became ready without reporting a port.
  case noPort
  /// The server could not write to a connection.
  case sendFailed(String)
}

/// Starts a listener on an ephemeral loopback port and waits until it is ready.
enum ListenerStart {
  /// Starts `listener` and returns its port once it reports `ready`. The connection handler is
  /// installed before the listener starts, because Network.framework rejects a listener that
  /// starts without one.
  /// - Parameters:
  ///   - listener: A listener that has not been started.
  ///   - queue: The queue the listener's callbacks run on.
  ///   - onConnection: Receives each accepted connection.
  /// - Returns: The bound port.
  /// - Throws: The listener's failure if it fails before becoming ready.
  static func start(
    _ listener: NWListener,
    queue: DispatchQueue,
    onConnection: @escaping @Sendable (NWConnection) -> Void
  ) async throws -> UInt16 {
    listener.newConnectionHandler = onConnection
    return try await withCheckedThrowingContinuation { continuation in
      let resumed = Mutex(false)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          guard resumeOnce(resumed) else { return }
          guard let port = listener.port?.rawValue else {
            continuation.resume(throwing: TestServerError.noPort)
            return
          }
          continuation.resume(returning: port)
        case .failed(let error):
          guard resumeOnce(resumed) else { return }
          continuation.resume(throwing: error)
        default:
          return
        }
      }
      listener.start(queue: queue)
    }
  }
}

/// Returns true the first time it is called and false afterwards, so a continuation is resumed
/// once.
private func resumeOnce(_ flag: borrowing Mutex<Bool>) -> Bool {
  flag.withLock { resumed -> Bool in
    let first = !resumed
    resumed = true
    return first
  }
}
