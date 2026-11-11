import Synchronization

/// Holds requests to one route until the test releases them, to catch the app mid-request.
public final class RouteGate: Sendable {
  private struct State {
    var arrivals = 0
    var isReleased = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  /// Creates a closed gate.
  public init() {}

  /// Requests that reached the gate so far.
  public var arrivals: Int { state.withLock { $0.arrivals } }

  /// Waits here until the gate is released; returns at once after that.
  public func pass() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let isOpen = state.withLock { state -> Bool in
        state.arrivals += 1
        if state.isReleased { return true }
        state.waiters.append(continuation)
        return false
      }
      if isOpen { continuation.resume() }
    }
  }

  /// Lets through every request waiting at the gate, and every later one.
  public func release() {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.isReleased = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}
