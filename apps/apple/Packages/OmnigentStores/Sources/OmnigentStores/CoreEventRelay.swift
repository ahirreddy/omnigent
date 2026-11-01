public import OmnigentCoreFFI

/// Forwards core events, in order, from the core's background thread to one async sequence the
/// stores consume on the main actor.
nonisolated final class CoreEventRelay: CoreListener, Sendable {
  let events: AsyncStream<CoreEvent>
  private let continuation: AsyncStream<CoreEvent>.Continuation

  init() {
    (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
  }

  func onEvent(event: CoreEvent) {
    continuation.yield(event)
  }

  func finish() {
    continuation.finish()
  }
}
