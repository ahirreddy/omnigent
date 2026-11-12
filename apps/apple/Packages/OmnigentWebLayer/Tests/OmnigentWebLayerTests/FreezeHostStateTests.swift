import AppKit
import Darwin
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// What a freeze line says about the host process and the channel to it.
@MainActor
@Suite("Freeze diagnostics about the host", .serialized)
struct FreezeHostStateTests {
  private func fixture() -> (ProtocolFixture, FreezeClock) {
    let fixture = ProtocolFixture()
    let clock = FreezeClock()
    fixture.session.uptimeNanos = { clock.nanos }
    return (fixture, clock)
  }

  /// A view sent a click and waits for its frame, so each tick samples the host.
  private func click(_ fixture: ProtocolFixture) throws {
    fixture.webView.renderer.forwardMouseEvent(
      try Offscreen.mouseEvent(.leftMouseDown), location: .zero)
  }

  private func value(of key: String, in text: String) -> Int? {
    text.split(separator: " ").first { $0.hasPrefix("\(key)=") }
      .flatMap { Int($0.dropFirst(key.count + 1)) }
  }

  @Test("the host's share of a core is measured between ticks, only while a view waits")
  func hostCPUShare() throws {
    let (fixture, clock) = fixture()
    let session = fixture.session
    let process = try HostProcess(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
    defer { process.kill() }
    session.process = process
    var cpuNanos: UInt64? = 5_000_000_000
    var sampled: [pid_t] = []
    session.hostCPUNanos = { pid in
      sampled.append(pid)
      return cpuNanos
    }
    let host = "host=pid:\(process.pid),running:1,cpu_pct:"

    session.freezeTick()
    #expect(sampled.isEmpty, "nothing waits for a frame, so the host is not sampled")
    try click(fixture)
    clock.advance(seconds: 1)
    session.freezeTick()
    #expect(sampled == [process.pid])
    #expect(session.freezeStateText(now: clock.nanos).hasPrefix("\(host)unknown "), "one sample")

    cpuNanos = 5_500_000_000
    clock.advance(seconds: 1)
    session.freezeTick()
    #expect(session.freezeStateText(now: clock.nanos).hasPrefix("\(host)50 "))
    #expect(session.freezeLines.last?.contains(" \(host)50 ping_ms=0 ") == true)

    // A count that fell is another process's: the share is not computed from it.
    cpuNanos = 1_000_000
    clock.advance(seconds: 1)
    session.freezeTick()
    #expect(session.freezeStateText(now: clock.nanos).hasPrefix("\(host)50 "))

    cpuNanos = nil
    clock.advance(seconds: 1)
    session.freezeTick()
    #expect(
      session.freezeStateText(now: clock.nanos).hasPrefix("\(host)unknown "),
      "the kernel would not say")
  }

  @Test("the line says how long a ping has waited, what the channel holds and what it refused")
  func pingAndChannel() throws {
    let (fixture, clock) = fixture()
    let session = fixture.session
    #expect(
      session.freezeStateText(now: clock.nanos)
        .contains(" ping_ms=0 recv_queue=-1 send_failures=0 "))

    let channel = try HostChannel.listen(
      serviceName: "ai.omnigent.owl.test.\(getpid()).\(UUID().uuidString.prefix(8))")
    try channel.adoptPeer(try FakeHost.sendRight())
    session.channel = channel
    defer { session.tearDownConnection() }
    session.outstandingPing = (id: 7, sent: ContinuousClock.now.advanced(by: .milliseconds(-1500)))
    let waiting = session.freezeStateText(now: clock.nanos)
    #expect((value(of: "ping_ms", in: waiting) ?? 0) >= 1500, "\(waiting)")
    #expect(value(of: "recv_queue", in: waiting) == 0, "\(waiting)")

    // The channel closes under the session: what it then refuses is counted.
    session.outgoingTap = nil
    channel.invalidate()
    #expect(channel.receiveBacklog == -1)
    #expect(throws: WebLayerError.channelFailed("The channel is closed.")) {
      try session.post(.ping, target: 0)
    }
    #expect(
      session.freezeStateText(now: clock.nanos).contains(" recv_queue=-1 send_failures=1 "))
  }
}
