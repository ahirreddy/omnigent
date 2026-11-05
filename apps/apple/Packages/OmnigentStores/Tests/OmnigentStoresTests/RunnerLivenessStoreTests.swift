import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@Suite("Runner and host liveness")
struct RunnerLivenessStoreTests {
  private func host(_ id: String, _ status: String, sandbox: String? = nil) -> CreationHost {
    CreationHost(
      hostId: id, name: "Host \(id)", status: status, sandboxProvider: sandbox,
      configuredHarnesses: nil)
  }

  @Test("a host counts as offline only after it was seen online; sandboxes never count")
  func hostOfflineWatch() {
    var watch = HostOfflineWatch()
    let first = watch.observe([
      host("a", "offline"), host("b", "online"), host("s", "online", sandbox: "arca"),
    ])
    #expect(first.isEmpty)
    let offline = watch.observe([
      host("a", "offline"), host("b", "offline"), host("s", "offline", sandbox: "arca"),
    ])
    #expect(offline == [HostWentOffline(hostID: "b", name: "Host b")])
    #expect(watch.observe([host("b", "offline")]).isEmpty)
  }

  @Test("offline hosts queue until the notifier takes them; a failed read changes nothing")
  func offlineHostsQueue() {
    let offlineHosts = OfflineHosts()
    offlineHosts.observe([host("b", "online")])
    offlineHosts.observe([])
    offlineHosts.observe([host("b", "offline")])
    #expect(offlineHosts.take() == [HostWentOffline(hostID: "b", name: "Host b")])
    #expect(offlineHosts.pending.isEmpty)
  }

  @Test("a runner-offline terminal read is panel state, not a session error")
  func runnerUnavailableIsNotASessionError() throws {
    let core = try ClientCore(
      http: FakeHttpTransport(failingWith: .Other(message: "unused")),
      streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(), clock: SystemClock(),
      scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let conversation = ConversationStore(sessionID: "s1", core: core)
    let asleep = CoreError.Terminal(
      kind: .runnerUnavailable,
      message: "the session's runner is unavailable (HTTP 503): offline", requiresSignIn: false)
    conversation.record(asleep)
    #expect(conversation.errors.isEmpty)
    #expect(conversation.runnerUnavailable == asleep)
    conversation.record(.Terminal(kind: .forbidden, message: "no", requiresSignIn: false))
    #expect(conversation.errors.count == 1)
  }
}
