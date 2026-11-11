public import OmnigentCoreFFI
import Synchronization

/// Forwards core events, in order, from the core's background thread to one async sequence the
/// stores consume on the main actor.
nonisolated final class CoreEventRelay: CoreListener, Sendable {
  let events: AsyncStream<CoreEvent>
  private let continuation: AsyncStream<CoreEvent>.Continuation
  private let sent = Mutex(0)

  /// How many events the core has sent so far.
  var eventsSent: Int { sent.withLock { $0 } }

  init() {
    (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
  }

  func onEvent(event: CoreEvent) {
    sent.withLock { count in
      continuation.yield(event)
      count += 1
    }
  }

  func finish() {
    continuation.finish()
  }
}
