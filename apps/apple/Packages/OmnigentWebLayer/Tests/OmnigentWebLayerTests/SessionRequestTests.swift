import Darwin
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

@MainActor
@Suite("Requests that wait for the host", .serialized)
struct SessionRequestTests {
  /// A ready session whose channel has a peer, so requests are sent and wait for a reply.
  private func connected(timeout: Duration = .seconds(30)) throws -> ProtocolFixture {
    var configuration = SessionConfiguration(
      hostAppURL: URL(fileURLWithPath: "/nonexistent"),
      rootCacheURL: FileManager.default.temporaryDirectory)
    configuration.requestTimeout = timeout
    let fixture = ProtocolFixture(configuration: configuration)
    let channel = try HostChannel.listen(
      serviceName: "ai.omnigent.owl.test.\(getpid()).\(UUID().uuidString.prefix(8))")
    try channel.adoptPeer(try FakeHost.sendRight())
    fixture.session.channel = channel
    return fixture
  }

  private func answer(
    _ fixture: ProtocolFixture, _ fields: WireEncoder
  ) async throws {
    #expect(await fixture.eventually { !fixture.session.replies.isEmpty })
    let id = try #require(fixture.session.replies.keys.first)
    fixture.session.handle(
      IncomingMessage(
        kindValue: .max, request: id, target: 0, protocolMajor: 1,
        fields: try WireDecoder(fields.bytes), port: nil))
  }

  @Test func evaluationRepliesAreParsed() async throws {
    let fixture = try connected()
    defer { fixture.session.tearDownConnection() }
    let good = Task { try await fixture.webView.evaluateJavaScript("1") }
    try await answer(
      fixture, WireEncoder().bool(.success, true).string(.JSON, #"{"result":{"value":2}}"#))
    #expect(try await good.value == .number(2))

    let bad = Task { try await fixture.webView.evaluateJavaScript("1") }
    try await answer(fixture, WireEncoder().string(.JSON, #"{"message":"nope"}"#))
    await #expect(throws: WebLayerError.devToolsFailed(method: "Runtime.evaluate", message: "nope"))
    {
      try await bad.value
    }
    let empty = Task { try await fixture.webView.evaluateJavaScript("1") }
    try await answer(fixture, WireEncoder().bool(.success, true))
    await #expect(throws: WebLayerError.self) { try await empty.value }
  }

  @Test func snapshotAndDevToolsReplies() async throws {
    let fixture = try connected()
    defer { fixture.session.tearDownConnection() }
    let png = Task { try await fixture.webView.snapshotPNG() }
    try await answer(fixture, WireEncoder().bool(.success, true).bytes(.PNG, [1, 2]))
    #expect(try await png.value == Data([1, 2]))
    let missing = Task { try await fixture.webView.snapshotPNG() }
    try await answer(fixture, WireEncoder().bool(.success, true))
    await #expect(throws: WebLayerError.snapshotFailed("The host returned no image.")) {
      try await missing.value
    }
    let method = Task { try await fixture.webView.callDevToolsMethod("A.b", paramsJSON: "{}") }
    try await answer(fixture, WireEncoder().bool(.success, true).string(.JSON, "{}"))
    #expect(try await method.value == "{}")
    let failed = Task { try await fixture.webView.callDevToolsMethod("A.b") }
    try await answer(fixture, WireEncoder())
    await #expect(throws: WebLayerError.devToolsFailed(method: "A.b", message: "")) {
      try await failed.value
    }
  }

  @Test func aRequestThatIsNeverAnsweredTimesOut() async throws {
    let fixture = try connected(timeout: .milliseconds(10))
    defer { fixture.session.tearDownConnection() }
    await #expect(throws: WebLayerError.self) { try await fixture.webView.snapshotPNG() }
    #expect(fixture.session.replies.isEmpty)
  }

  @Test func aSendThatFailsAnswersTheRequest() async throws {
    let fixture = try connected()
    fixture.session.channel?.invalidate()
    await #expect(throws: WebLayerError.channelFailed("The channel is closed.")) {
      try await fixture.webView.snapshotPNG()
    }
    fixture.session.tearDownConnection()
  }

  @Test func waitingRequestsFailWhenTheHostGoesAway() async throws {
    let fixture = try connected()
    let pending = Task { try await fixture.webView.snapshotPNG() }
    #expect(await fixture.eventually { !fixture.session.replies.isEmpty })
    fixture.session.failReplies(.viewClosed)
    await #expect(throws: WebLayerError.viewClosed) { try await pending.value }
    fixture.session.tearDownConnection()
  }

  @Test func liveRequestsNameWhyTheyCannotRun() async {
    let fixture = ProtocolFixture()
    fixture.webView.status = .unavailable(.launchFailed("x"))
    await #expect(throws: WebLayerError.launchFailed("x")) {
      try await fixture.webView.snapshotPNG()
    }
    fixture.webView.status = .closed
    await #expect(throws: WebLayerError.viewClosed) { try await fixture.webView.snapshotPNG() }
    await #expect(throws: WebLayerError.viewClosed) { try await fixture.webView.find("x") }
  }
}

@MainActor
@Suite("Deleting a profile's storage", .serialized)
struct ProfileStorageTests {
  private func session() -> (Session, URL) {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "owl-tests-\(UUID().uuidString)")
    return (
      Session(
        configuration: SessionConfiguration(
          hostAppURL: URL(fileURLWithPath: "/nonexistent"), rootCacheURL: root)),
      root
    )
  }

  @Test func deletingRemovesTheDirectoryAndQueuesIt() throws {
    let (session, root) = session()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = session.storageDirectory(forProfileIdentifier: "../../evil")
    #expect(directory.lastPathComponent.hasPrefix("Profile-"))
    #expect(!directory.path.contains("evil"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let profile = session.profile(identifier: "../../evil", persistence: .persistent)
    #expect(try session.deletePersistentStorage(identifier: "../../evil"))
    #expect(profile.isClosed)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(try session.deletePersistentStorage(identifier: "../../evil"))
    let queued = try JSONDecoder().decode(
      [String].self, from: Data(contentsOf: session.pendingDeletionsURL))
    #expect(queued.count == 1)
    try session.sweepPendingDeletions()
    let swept = try JSONDecoder().decode(
      [String].self, from: Data(contentsOf: session.pendingDeletionsURL))
    #expect(swept.isEmpty)
  }

  @Test func aCorruptQueueIsAnErrorNotACrash() throws {
    let (session, root) = session()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for text in ["", "{}", "[1]", String(repeating: "[", count: 100_000)] {
      try text.write(to: session.pendingDeletionsURL, atomically: true, encoding: .utf8)
      #expect(throws: WebLayerError.self) { try session.deletePersistentStorage(identifier: "x") }
      #expect(throws: WebLayerError.self) { try session.sweepPendingDeletions() }
    }
  }

  @Test func aRootThatCannotHoldTheQueueIsAnError() throws {
    let (session, root) = session()
    defer { try? FileManager.default.removeItem(at: root) }
    try "a file".write(to: root, atomically: true, encoding: .utf8)
    #expect(throws: WebLayerError.self) { try session.deletePersistentStorage(identifier: "x") }
  }

  @Test func aDirectoryThatCannotBeRemovedStaysQueued() throws {
    let (session, root) = session()
    let directory = session.storageDirectory(forProfileIdentifier: "x")
    let child = directory.appending(path: "held")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? FileManager.default.removeItem(at: root)
    }
    #expect(try !session.deletePersistentStorage(identifier: "x"))
    #expect(throws: WebLayerError.self) { try session.sweepPendingDeletions() }
  }
}
