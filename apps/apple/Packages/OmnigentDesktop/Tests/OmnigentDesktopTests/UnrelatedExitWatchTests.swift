import Darwin
import Testing

@testable import OmnigentDesktop

/// Waiting for a process the app didn't start, where the wait can end before it begins.
@Suite("Unrelated exit watch")
struct UnrelatedExitWatchTests {
  @Test("cancelling the wait for an unrelated process ends it without that process exiting")
  func cancelledWait() async {
    let wait = Task { await PosixSpawnProcessRunner().waitForExit(ofUnrelated: getpid()) }
    await Task.yield()
    wait.cancel()
    await wait.value
    #expect(PosixSpawnProcessRunner().identity(of: getpid()) != nil)
  }

  @Test("a watch finished before it starts returns at once")
  func finishedWatch() async {
    let watch = UnrelatedExitWatch(pid: getpid())
    watch.finish()
    await watch.wait(isAlive: { true })
    watch.finish()
  }
}
