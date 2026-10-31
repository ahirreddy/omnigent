import Foundation
import XCTest

@testable import NativeLabCore

final class SessionExecutionReadinessTests: XCTestCase {
  func testReadinessUsesExecutionMetadataRatherThanHarnessOrPermissions() throws {
    let scenarios: [(String, [String: Any], Bool)] = [
      ("unbound offline runner", ["runner_online": false, "host_online": NSNull()], false),
      (
        "unbound fixture with null liveness",
        [
          "harness": "codex-native", "runner_id": NSNull(), "runner_online": NSNull(),
          "host_id": NSNull(),
        ], false
      ),
      (
        "native fixture reported online by legacy liveness",
        [
          "harness": "codex-native", "runner_id": NSNull(), "runner_online": true,
          "host_id": NSNull(),
        ], false
      ),
      (
        "in-process executor needs no runner binding",
        [
          "harness": "openai-agents", "runner_id": NSNull(), "runner_online": true,
          "host_id": NSNull(),
        ], true
      ),
      ("bound runner with unknown liveness", ["runner_id": "runner1"], true),
      ("unbound online runner", ["runner_online": true], true),
      ("unknown legacy liveness", [:], true),
      ("unknown runner", ["runner_online": NSNull()], true),
      (
        "online host relaunches without managed resume",
        ["host_id": "mac", "host_online": true, "runner_online": false, "host_resumable": false],
        true
      ),
      (
        "online host with missing resume capability",
        ["host_id": "mac", "host_online": true, "runner_online": false], true
      ),
      (
        "managed host can wake",
        [
          "host_id": "managed", "host_online": false, "runner_online": false,
          "host_resumable": true,
        ],
        true
      ),
      (
        "offline host cannot wake",
        ["host_id": "mac", "host_online": false, "runner_online": false, "host_resumable": false],
        false
      ),
      (
        "host liveness not yet known", ["host_id": "mac", "runner_online": false], true
      ),
      (
        "online runner takes precedence",
        ["host_id": "mac", "host_online": false, "runner_online": true], true
      ),
      (
        "resumability without a host cannot execute",
        ["runner_online": false, "host_resumable": true], false
      ),
    ]
    for (name, fields, available) in scenarios {
      let value = try summary(fields)
      XCTAssertEqual(value.configuration?.executionUnavailableReason == nil, available, name)
      XCTAssertFalse(value.isReadOnly, name)
      XCTAssertTrue(value.canRename, name)
    }
  }

  func testSparseProjectionKeepsNoConnectionReasonAndWritePermissions() throws {
    let initial = try summary([
      "host_id": NSNull(), "host_online": NSNull(), "runner_id": NSNull(),
      "runner_online": true, "harness": "codex-native",
    ])
    let projected = try summary([:], previous: initial, includePermission: false)
    XCTAssertEqual(
      projected.configuration?.executionUnavailableReason,
      initial.configuration?.executionUnavailableReason)
    XCTAssertTrue(
      projected.configuration?.executionUnavailableReason?.contains("tap New session") == true)
    XCTAssertFalse(projected.isReadOnly)
    XCTAssertEqual(projected.configuration?.runnerBound, false)
    XCTAssertEqual(projected.permissionLevel, 4)
  }

  func testSparseProjectionPreservesManagedResumeButExplicitFalseDisablesIt() throws {
    let initial = try summary([
      "host_id": "managed", "host_online": false, "runner_online": false, "host_resumable": true,
    ])
    let projected = try summary(["runner_online": false], previous: initial)
    XCTAssertEqual(projected.configuration?.hostResumable, true)
    XCTAssertNil(projected.configuration?.executionUnavailableReason)
    let disabled = try summary(["host_resumable": false], previous: projected)
    XCTAssertEqual(disabled.configuration?.hostResumable, false)
    XCTAssertTrue(
      disabled.configuration?.executionUnavailableReason?.contains("host is offline") == true)
  }

  func testExplicitNullClearsResumeAndChangingHostsClearsOldLiveness() throws {
    let initial = try summary([
      "host_id": "managed", "host_online": false, "runner_online": false, "host_resumable": true,
    ])
    let cleared = try summary(["host_resumable": NSNull()], previous: initial)
    XCTAssertNil(cleared.configuration?.hostResumable)
    XCTAssertNotNil(cleared.configuration?.executionUnavailableReason)
    let moved = try summary(["host_id": "other"], previous: initial)
    XCTAssertNil(moved.configuration?.hostOnline)
    XCTAssertNil(moved.configuration?.runnerOnline)
    XCTAssertNil(moved.configuration?.hostResumable)
    XCTAssertNil(moved.configuration?.executionUnavailableReason)
    let unbound = try summary(
      ["host_id": NSNull(), "host_online": NSNull(), "runner_online": false], previous: initial)
    XCTAssertNil(unbound.configuration?.hostResumable)
    XCTAssertNotNil(unbound.configuration?.executionUnavailableReason)
  }

  func testHarnessChangeDoesNotEraseSessionExecutionMetadata() throws {
    let initial = try summary([
      "harness": "codex-native", "host_id": "managed", "host_online": false,
      "runner_online": false, "host_resumable": true,
    ])
    let changed = try summary(["harness": "claude-native"], previous: initial)
    XCTAssertEqual(changed.configuration?.hostID, "managed")
    XCTAssertEqual(changed.configuration?.hostOnline, false)
    XCTAssertEqual(changed.configuration?.runnerOnline, false)
    XCTAssertEqual(changed.configuration?.hostResumable, true)
    XCTAssertNil(changed.configuration?.executionUnavailableReason)
  }

  func testOlderSavedConfigurationWithoutResumabilityRemainsDecodable() throws {
    let value = try JSONDecoder().decode(
      SessionConfiguration.self,
      from: Data(#"{"hostID":"mac","hostOnline":true,"runnerOnline":false,"models":[]}"#.utf8))
    XCTAssertNil(value.hostResumable)
    XCTAssertNil(value.executionUnavailableReason)
  }

  func testUnboundFailedSessionKeepsFailureHistorySeparateFromReadiness() throws {
    let value = try summary(["status": "failed", "runner_online": false])
    XCTAssertNotNil(value.failureMessage)
    XCTAssertTrue(
      value.configuration?.executionUnavailableReason?.contains("no execution connection") == true)
    XCTAssertFalse(value.isReadOnly)
  }

  func testUnavailableSessionNeverPostsTextOrAttachmentMessage() async throws {
    for fields: [String: Any] in [
      [
        "harness": "codex-native", "runner_id": NSNull(), "runner_online": true,
        "host_id": NSNull(),
      ],
      ["runner_online": false, "host_online": NSNull()],
      ["host_id": "mac", "host_online": false, "runner_online": false, "host_resumable": false],
    ] {
      let harness = TransportHarness()
      harness.respond(path: path, body: try wire(fields))
      let client = try harness.makeClient()
      _ = try await client.connect()
      await client.primeStreamForTesting("conv_a")
      let reason = try XCTUnwrap(summary(fields).configuration?.executionUnavailableReason)
      let serverURL = await client.baseURL
      let file = UploadedAttachment(
        serverURL: serverURL, sessionID: "conv_a", id: "file1", filename: "draft.txt",
        isImage: false)
      for attachments in [[], [file]] {
        do {
          _ = try await client.submitMessage(
            "Keep this draft", attachments: attachments, to: "conv_a")
          XCTFail("Unavailable session accepted input")
        } catch {
          XCTAssertEqual(error as? LocalServerClientError, .executionUnavailable(reason))
        }
      }
      XCTAssertFalse(harness.requests.contains { $0.httpMethod != "GET" })
      await client.stopWatching()
    }
  }

  func testConnectedHostAndWakeableHostAllowStoppedRunnerSubmissions() async throws {
    for (online, resumable) in [(true, false), (false, true)] {
      let harness = TransportHarness()
      harness.respond(
        path: path,
        body: try wire([
          "host_id": "mac", "host_online": online, "runner_online": false,
          "host_resumable": resumable,
        ]))
      harness.respond(path: path + "/events", body: #"{"queued":true}"#, status: 202)
      let client = try harness.makeClient()
      _ = try await client.connect()
      await client.primeStreamForTesting("conv_a")
      let result = try await client.submitMessage("Wake this session", to: "conv_a")
      XCTAssertTrue(result.queued)
      XCTAssertEqual(harness.requests.filter { $0.httpMethod == "POST" }.count, 1)
      await client.stopWatching()
    }
  }

  func testSparsePushUpdatesReadinessAndPreventsStaleSnapshotRestoringOnlineState() async throws {
    let harness = TransportHarness()
    let original = try wire(["host_id": NSNull(), "runner_online": true])
    harness.respond(path: path, body: original)
    let client = try harness.makeClient()
    _ = try await client.connect()
    _ = try await client.editableSession("conv_a")
    let epoch = await client.configurationEpochs["conv_a", default: 0]
    let sparse = try wire(["runner_online": false], includePermission: false)
    try await client.handleListMessage(Data("{\"type\":\"changed\",\"items\":[\(sparse)]}".utf8))
    let stale = try JSONDecoder().decode(SessionWire.self, from: Data(original.utf8))
    let retained = try await client.summaryPreservingNewerState(stale, epoch: epoch)
    XCTAssertEqual(retained.configuration?.runnerOnline, false)
    XCTAssertNotNil(retained.configuration?.executionUnavailableReason)
    XCTAssertFalse(retained.isReadOnly)
    let recovering = try wire(
      ["host_id": "mac", "host_online": true, "runner_online": false, "host_resumable": false],
      includePermission: false)
    try await client.handleListMessage(
      Data("{\"type\":\"changed\",\"items\":[\(recovering)]}".utf8))
    let current = await client.summaries["conv_a"]
    XCTAssertNil(current?.configuration?.executionUnavailableReason)
    XCTAssertFalse(try XCTUnwrap(current).isReadOnly)
    XCTAssertFalse(harness.requests.contains { $0.httpMethod != "GET" })
  }

  private let path = "/v1/sessions/conv_a"

  private func wire(_ fields: [String: Any], includePermission: Bool = true) throws -> String {
    var base: [String: Any] = ["id": "conv_a", "status": "idle", "created_at": 1]
    if includePermission { base["permission_level"] = 4 }
    return String(
      decoding: try JSONSerialization.data(withJSONObject: base.merging(fields) { _, new in new }),
      as: UTF8.self)
  }

  private func summary(
    _ fields: [String: Any], previous: SessionSummary? = nil, includePermission: Bool = true
  ) throws -> SessionSummary {
    try JSONDecoder().decode(
      SessionWire.self, from: Data(wire(fields, includePermission: includePermission).utf8)
    ).summary(previous: previous)
  }
}
