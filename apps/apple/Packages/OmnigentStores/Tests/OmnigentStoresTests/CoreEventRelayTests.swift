import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

/// The relay hands the stores every event the core sent while they were busy, together and in
/// order, so a burst is applied in one main-actor turn and the views draw once for it.
@Suite("Core event relay")
struct CoreEventRelayTests {
  @Test("Events sent while the consumer is busy come out together, in order, once")
  func drainsABurstInOrder() async {
    let relay = CoreEventRelay()
    relay.onEvent(event: .sessionListLoaded)
    relay.onEvent(event: .unreadChanged(sessionIds: ["a"]))
    relay.onEvent(event: .offlineChanged(serverUrl: nil))
    #expect(relay.eventsSent == 3)
    var wakes = relay.wakes.makeAsyncIterator()
    #expect(await wakes.next() != nil)
    let burst = relay.drain().map { SidebarLoadSignposts.kind(of: $0) }
    #expect(burst == ["loaded", "unread 1", "offline false"])
    #expect(relay.drain().isEmpty)
    relay.onEvent(event: .sessionListLoaded)
    #expect(await wakes.next() != nil)
    #expect(relay.drain().map { SidebarLoadSignposts.kind(of: $0) } == ["loaded"])
    relay.finish()
    #expect(await wakes.next() == nil)
  }
}
