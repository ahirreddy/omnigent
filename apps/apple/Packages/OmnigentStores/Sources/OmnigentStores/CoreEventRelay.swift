public import OmnigentCoreFFI
import Synchronization

/// Forwards core events, in order, from the core's background thread to the stores on the main
/// actor. The events sent while the main actor is busy are taken together (``drain()``), so a
/// burst of them is applied in one turn and the views draw once for it, not once per event.
nonisolated final class CoreEventRelay: CoreListener, Sendable {
  /// Wakes the consumer; one waiting wake stands for every event sent since the last drain.
  let wakes: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let state = Mutex(Pending())

  private struct Pending {
    var events: [CoreEvent] = []
    var sent = 0
  }

  /// How many events the core has sent so far.
  var eventsSent: Int { state.withLock { $0.sent } }

  init() {
    (wakes, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  func onEvent(event: CoreEvent) {
    if SidebarLoadSignposts.isEnabled, let kind = SidebarLoadSignposts.kind(of: event) {
      SidebarLoadSignposts.mark("core event", kind)
    }
    state.withLock { pending in
      pending.events.append(event)
      pending.sent += 1
    }
    continuation.yield()
  }

  /// The events sent since the last drain, in order.
  func drain() -> [CoreEvent] {
    state.withLock { pending in
      let events = pending.events
      pending.events = []
      return events
    }
  }

  func finish() {
    continuation.finish()
  }
}
