import Observation
import Synchronization
import Testing

@testable import OmnigentDesktop

@Suite("Deferred observed value")
@MainActor
struct DeferredObservedValueTests {
  @Test("reads the value at creation")
  func initialValue() {
    let source = FakeMenuBarSessionSource(unreadCount: 2)
    let deferred = DeferredObservedValue { source.unreadCount }
    #expect(deferred.value == 2)
  }

  @Test("publishes a change on a later main-actor turn, not during it")
  func publishesLater() async {
    let source = FakeMenuBarSessionSource(unreadCount: 0)
    let deferred = DeferredObservedValue { source.unreadCount }
    source.unreadCount = 1
    source.unreadCount = 3
    #expect(deferred.value == 0)
    await waitForValue(deferred, 3)
    #expect(deferred.value == 3)

    source.unreadCount = 4
    #expect(deferred.value == 3)
    await waitForValue(deferred, 4)
    #expect(deferred.value == 4)
  }

  @Test("an unchanged value does not notify its observers")
  func unchangedValueIsQuiet() async {
    let source = FakeMenuBarSessionSource(unreadCount: 1)
    let deferred = DeferredObservedValue { source.unreadCount > 0 }
    let notified = Mutex(false)
    withObservationTracking {
      _ = deferred.value
    } onChange: {
      notified.withLock { $0 = true }
    }
    source.unreadCount = 5
    await waitForTurns()
    #expect(deferred.value)
    #expect(!notified.withLock { $0 })
  }

  private func waitForValue<Value: Equatable>(
    _ deferred: DeferredObservedValue<Value>, _ expected: Value
  ) async {
    for _ in 0..<100 where deferred.value != expected {
      await Task.yield()
    }
  }

  private func waitForTurns() async {
    for _ in 0..<20 {
      await Task.yield()
    }
  }
}
