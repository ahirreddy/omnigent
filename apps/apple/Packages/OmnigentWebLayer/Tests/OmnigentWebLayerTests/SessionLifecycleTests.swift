import Darwin
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// A stand-in for the web host: a shell script at the bundle's executable path. It never loads a
/// browser, and each session's Mach service name is unique.
@MainActor
final class FakeHost {
  let root: URL
  let session: Session

  init(script: String, adjust: (inout SessionConfiguration) -> Void = { _ in }) throws {
    root = FileManager.default.temporaryDirectory.appending(path: "owl-tests-\(UUID().uuidString)")
    let app = root.appending(path: "\(SessionConfiguration.hostAppName).app")
    let directory = app.appending(path: "Contents/MacOS")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: SessionConfiguration.hostAppName)
    try "#!/bin/sh\n\(script)\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var configuration = SessionConfiguration(
      hostAppURL: app, rootCacheURL: root.appending(path: "cache"))
    configuration.shutdownGrace = .milliseconds(100)
    adjust(&configuration)
    session = Session(configuration: configuration)
  }

  func cleanUp() {
    session.process?.kill()
    session.tearDownConnection()
    try? FileManager.default.removeItem(at: root)
  }

  func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  /// A Hello as the running host would send it; a send right the channel can adopt comes with it.
  func hello(
    major: UInt64 = UInt64(OWL_PROTOCOL_MAJOR), header: UInt16 = UInt16(OWL_PROTOCOL_MAJOR),
    minor: UInt64 = UInt64(OWL_PROTOCOL_MINOR), token: String? = nil, pid: UInt64? = nil,
    withPort: Bool = true
  ) throws -> IncomingMessage {
    let fields = WireEncoder()
      .u64(.protocolMajor, major).u64(.protocolMinor, minor)
      .string(.token, token ?? session.token)
      .u64(.hostPID, pid ?? UInt64(session.process?.pid ?? 0))
    return IncomingMessage(
      kindValue: OWLMessageKind.hello.rawValue, request: 0, target: 0, protocolMajor: header,
      fields: try WireDecoder(fields.bytes), port: withPort ? try Self.sendRight() : nil)
  }

  static func sendRight() throws -> MachSendRight {
    var name = mach_port_t(MACH_PORT_NULL)
    let task = unsafe mach_task_self_
    let allocated = unsafe mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &name)
    #expect(allocated == KERN_SUCCESS)
    let made = mach_port_insert_right(
      task, name, name, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
    #expect(made == KERN_SUCCESS)
    return MachSendRight(name: name)
  }

  static func message(_ kind: OWLMessageKind, _ fields: WireEncoder = WireEncoder()) throws
    -> IncomingMessage
  {
    IncomingMessage(
      kindValue: kind.rawValue, request: 0, target: 0, protocolMajor: UInt16(OWL_PROTOCOL_MAJOR),
      fields: try WireDecoder(fields.bytes), port: nil)
  }
}

@MainActor
@Suite("Session lifecycle against a fake host", .serialized)
struct SessionLifecycleTests {
  @Test func aHostThatExitsFailsTheLaunch() async throws {
    let host = try FakeHost(script: "exit 7")
    defer { host.cleanUp() }
    let view = host.session.profile(identifier: "a", persistence: .ephemeral).makeWebView()
    host.session.start()
    #expect(host.session.state == .launching)
    host.session.start()
    #expect(await host.eventually { host.session.state != .launching })
    #expect(host.session.state == .failed(.hostExited(status: 7, reason: "exited")))
    #expect(view.status == .unavailable(.hostExited(status: 7, reason: "exited")))
  }

  @Test func aHostThatNeverSpeaksTimesOutOfTheHandshake() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20") {
      $0.handshakeTimeout = .milliseconds(50)
    }
    defer { host.cleanUp() }
    host.session.start()
    await #expect(throws: WebLayerError.self) {
      try await host.session.waitUntilReady(timeout: .seconds(10))
    }
    guard case .failed(.hostTimedOut(let phase, _)) = host.session.state else {
      Issue.record("expected a timeout, got \(host.session.state)")
      return
    }
    #expect(phase == "the handshake")
  }

  @Test func waitingGivesUpAtItsDeadline() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    await #expect(throws: WebLayerError.notReady) { try await host.session.waitUntilReady() }
    host.session.start()
    await #expect(throws: WebLayerError.hostTimedOut(phase: "start-up", seconds: 0)) {
      try await host.session.waitUntilReady(timeout: .milliseconds(10))
    }
  }

  @Test func restartAndShutdownEndTheHost() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.restart()
    let first = try #require(host.session.process)
    host.session.restart()
    let second = try #require(host.session.process)
    #expect(first.pid != second.pid)
    #expect(await host.eventually { !first.isRunning })
    host.session.shutdown()
    #expect(host.session.state == .stopped)
    #expect(host.session.process == nil)
    #expect(!second.isRunning)
    host.session.shutdown()
    #expect(host.session.state == .stopped)
  }

  @Test func theHandshakeRefusesWhatItDoesNotExpect() async throws {
    let cases: [(FakeHost) throws -> IncomingMessage] = [
      { try $0.hello(withPort: false) },
      { try $0.hello(major: 99) },
      { try $0.hello(header: 99) },
      { try $0.hello(token: "stolen") },
      { try $0.hello(pid: .max) },
    ]
    for make in cases {
      let host = try FakeHost(script: "exec /bin/sleep 20")
      defer { host.cleanUp() }
      host.session.start()
      host.session.handle(try make(host))
      #expect(await host.eventually { host.session.state != .launching })
      guard case .failed(let error) = host.session.state else {
        Issue.record("expected a failed launch, got \(host.session.state)")
        continue
      }
      switch error {
      case .handshakeFailed, .protocolMismatch: break
      default: Issue.record("unexpected error \(error)")
      }
    }
  }

  @Test func aFullHandshakeReachesReadyAndTheWatchdogKillsAHang() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20") {
      $0.pingInterval = .milliseconds(10)
      $0.hangTimeout = .milliseconds(30)
    }
    defer { host.cleanUp() }
    var sent: [OWLMessageKind] = []
    let profile = host.session.profile(identifier: "p", persistence: .persistent)
    let view = profile.makeWebView()
    host.session.outgoingTap = { kind, _, _ in sent.append(kind) }
    host.session.start()
    host.session.handle(try FakeHost.message(.pong))
    // Ready before Hello would be refused; Hello first.
    host.session.handle(try host.hello())
    #expect(host.session.helloInfo != nil)
    host.session.handle(
      try FakeHost.message(
        .ready, WireEncoder().u64(.renderMode, .max).u64(.elapsedMilliseconds, .max)))
    #expect(host.session.isReady)
    #expect(host.session.hostInfo?.protocolVersion == "1.\(OWL_PROTOCOL_MINOR)")
    #expect(sent == [.profileCreate, .viewCreate])
    #expect(view.status == .creating)
    #expect(await host.eventually { if case .crashed = host.session.state { true } else { false } })
    guard case .crashed(.hostUnresponsive) = host.session.state else {
      Issue.record("expected a hang, got \(host.session.state)")
      return
    }
    guard case .unavailable = view.status else {
      Issue.record("the view should be unavailable, it is \(view.status)")
      return
    }
  }

  @Test func readyBeforeHelloIsRefused() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    host.session.handle(try FakeHost.message(.ready))
    #expect(await host.eventually { host.session.state != .launching })
    #expect(host.session.state == .failed(.handshakeFailed("Ready arrived before Hello.")))
  }

  @Test func chromiumFailingToStartIsReported() async throws {
    let host = try FakeHost(script: "exec /bin/sleep 20")
    defer { host.cleanUp() }
    host.session.start()
    host.session.handle(try FakeHost.message(.initFailed))
    #expect(await host.eventually { host.session.state != .launching })
    #expect(host.session.state == .failed(.hostInitializationFailed("No reason given.")))
  }

  @Test func eventsFromAnOldGenerationAreIgnored() throws {
    let fixture = ProtocolFixture()
    let current = fixture.session.generation
    fixture.session.handle(.failure(.notReady), generation: current + 1)
    #expect(fixture.session.lastProtocolError == nil)
    fixture.session.handle(.failure(.notReady), generation: current)
    #expect(fixture.session.lastProtocolError == .notReady)
    fixture.session.handle(.peerDied, generation: current)
    #expect(fixture.session.timers.count == 1)
    fixture.session.tearDownConnection()
    #expect(fixture.session.timers.isEmpty)
    fixture.session.hostExited(status: 1, signaled: false, generation: current + 1)
    #expect(fixture.session.isReady)
    fixture.session.hostExited(status: 9, signaled: true, generation: current)
    #expect(fixture.session.state == .crashed(.hostExited(status: 9, reason: "killed by signal 9")))
  }

  @Test func hostErrorsFindWhoTheyAreFor() throws {
    let fixture = ProtocolFixture()
    let profile = fixture.webView.profile
    func report(_ code: OWLHostErrorCode, target: UInt64) throws {
      fixture.session.handle(
        IncomingMessage(
          kindValue: OWLMessageKind.hostError.rawValue, request: 0, target: target,
          protocolMajor: 1,
          fields: try WireDecoder(WireEncoder().u64(.errorCode, code.rawValue).bytes), port: nil))
    }
    try report(.unknownPrompt, target: fixture.webView.id)
    #expect(fixture.session.lastProtocolError != nil)
    #expect(fixture.webView.lastError == nil)
    try report(.viewCreateFailed, target: fixture.webView.id)
    guard case .unavailable = fixture.webView.status else {
      Issue.record("the view should be unavailable")
      return
    }
    try report(.viewCreateFailed, target: profile.id)
    #expect(profile.lastError != nil)
    fixture.session.lastProtocolError = nil
    try report(.viewCreateFailed, target: .max)
    #expect(fixture.session.lastProtocolError != nil)
  }

  @Test func profilesCloseWithTheirViews() throws {
    let fixture = ProtocolFixture()
    let profile = fixture.session.profile(identifier: "c", persistence: .ephemeral)
    #expect(fixture.last(.profileCreate) != nil)
    let view = profile.makeWebView()
    #expect(view.status == .creating)
    #expect(profile.views.first === view)
    profile.close()
    profile.close()
    #expect(profile.isClosed)
    #expect(view.status == .closed)
    #expect(fixture.last(.profileDestroy) != nil)
    #expect(fixture.session.existingProfile(identifier: "c", persistence: .ephemeral) == nil)
  }
}
