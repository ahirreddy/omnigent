import Testing

@testable import OmnigentStores

@Suite("Sleeping unless cancelled")
struct SleepUnlessCancelledTests {
  @Test("a cancelled wait returns at once")
  func cancelledReturnsAtOnce() async {
    let clock = ContinuousClock()
    let started = clock.now
    let wait = Task { await sleepUnlessCancelled(for: .seconds(60)) }
    wait.cancel()
    await wait.value
    #expect(started.duration(to: clock.now) < .seconds(30))
  }

  @Test("an uncancelled wait takes its time")
  func uncancelledWaits() async {
    let clock = ContinuousClock()
    let started = clock.now
    await sleepUnlessCancelled(for: .milliseconds(20))
    #expect(started.duration(to: clock.now) >= .milliseconds(20))
  }
}
