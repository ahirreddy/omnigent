import Synchronization

/// A FIFO hand-off between a producer that pushes values and a consumer that awaits them.
/// Values pushed before anyone waits are kept; waiters are served in arrival order.
final class Rendezvous<Value: Sendable>: Sendable {
  private struct State {
    var values: [Value] = []
    var waiters: [CheckedContinuation<Value, Never>] = []
  }

  private let state = Mutex(State())

  /// Hands `value` to the oldest waiter, or queues it when no one is waiting.
  func push(_ value: Value) {
    let waiter = state.withLock { state -> CheckedContinuation<Value, Never>? in
      if state.waiters.isEmpty {
        state.values.append(value)
        return nil
      }
      return state.waiters.removeFirst()
    }
    waiter?.resume(returning: value)
  }

  /// The oldest queued value, waiting for one if none is queued.
  func next() async -> Value {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
      let ready = state.withLock { state -> Value? in
        if state.values.isEmpty {
          state.waiters.append(continuation)
          return nil
        }
        return state.values.removeFirst()
      }
      if let ready {
        continuation.resume(returning: ready)
      }
    }
  }
}
