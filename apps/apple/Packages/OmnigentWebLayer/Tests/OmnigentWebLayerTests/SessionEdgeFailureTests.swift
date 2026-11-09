import Darwin
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// A value whose encoding fails, as a broken encoder would.
private struct RefusesToEncode: Encodable {
  func encode(to encoder: any Encoder) throws {
    throw CocoaError(.coderInvalidValue)
  }
}

@MainActor
@Suite("Session failures the system rarely gives", .serialized)
struct SessionEdgeFailureTests {
  @Test("waiting for a host that's already ready returns at once")
  func alreadyReady() async throws {
    let fixture = ProtocolFixture()
    try await fixture.session.waitUntilReady(timeout: .zero)
    #expect(fixture.session.isReady)
  }

  @Test("a file marked executable that can't run fails the launch and leaves nothing behind")
  func cannotRun() throws {
    let host = try FakeHost(script: "exit 0")
    defer { host.cleanUp() }
    let executable = host.root
      .appending(path: "\(SessionConfiguration.hostAppName).app/Contents/MacOS")
      .appending(path: SessionConfiguration.hostAppName)
    try Data([0, 1, 2, 3]).write(to: executable)
    host.session.start()
    guard case .failed(.launchFailed) = host.session.state else {
      Issue.record("expected a failed launch, got \(host.session.state)")
      return
    }
    #expect(host.session.process == nil)
    #expect(host.session.channel == nil)
  }

  @Test("a macOS without remote layers starts on the IOSurface path")
  func remoteLayersMissing() throws {
    let host = try FakeHost(script: "exec /bin/sleep 20") { $0.renderMode = .remoteLayer }
    defer { host.cleanUp() }
    host.session.remoteLayerSupported = { false }
    host.session.start()
    #expect(host.session.requestedMode == .ioSurface)
  }

  @Test("a host that survives SIGKILL is reported, and its exit handler can be read back")
  func survivesKill() throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    let process = try #require(host.session.process)
    #expect(process.onExit != nil)
    var signals: [Int32] = []
    process.sendSignal = { _, signal in
      signals.append(signal)
      errno = EPERM
      return -1
    }
    host.session.shutdown()
    #expect(signals.allSatisfy { $0 == SIGKILL })
    #expect(!signals.isEmpty)
    #expect(process.isRunning)
    process.sendSignal = Darwin.kill
    process.kill()
    #expect(process.waitForExit(timeout: .seconds(2)))
  }

  @Test("a host that signs on with a context this macOS can't embed reports it on the view")
  func remoteContextRefused() throws {
    let fixture = ProtocolFixture()
    fixture.webView.layerHost.remoteLayerClassName = "NoSuchLayerClass"
    try fixture.receive(.layerContext, WireEncoder().u64(.contextID, 1))
    #expect(fixture.webView.lastError != nil)
  }

  @Test("JSON that can't be encoded fails instead of being sent")
  func jsonRefused() {
    #expect(throws: WebLayerError.self) { _ = try WireJSON.encoded(RefusesToEncode()) }
    #expect(throws: WebLayerError.self) { _ = try WireJSON.text(ofJSON: Data([0xFF])) }
  }
}
