import Foundation
import OmnigentCoreFFI
import OmnigentStores
import Testing

// Shared by OmnigentMacTests and OmnigentMacAppStoreTests, so it runs inside each edition's app
// process; the App Store one is the sandbox's networking check.

/// A turn against a live server whose session streams replies from a mock model, through the
/// stores the app uses and the edition's real transports: the reply streams in, and Stop ends
/// a slow one early with the reply marked interrupted. The window around it is covered by the
/// package tests; reconnecting and de-duplication by the core's.
///
/// Runs when `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_E2E_SESSION_ID` are set (with the
/// `TEST_RUNNER_` prefix for `xcodebuild`); `OMNIGENT_E2E_TAG` is the mock's per-run tag. Each
/// message carries `<tag>-step<n>`, which the mock routes its replies by.
@MainActor
@Suite("Live server streaming", .enabled(if: LiveServer.current != nil), .serialized)
struct LiveServerStreamingTests {
  @Test func aReplyStreamsAndStopEndsASlowOne() async throws {
    let live = try #require(LiveServer.current)
    let connection = ConnectionStore()
    await connection.connect(serverURL: live.url)
    guard connection.isSignedIn else {
      throw LiveServerError("not connected: \(connection.phase)")
    }
    let conversation = try #require(connection.conversation(live.sessionID))
    defer { connection.closeConversation(live.sessionID) }
    #expect(try await eventually(seconds: 30) { conversation.isHydrated }, "history did not load")

    // A reply streams in, and the turn ends.
    let hello = "[\(live.tag)-hello]"
    try await send("Say hello, please. \(live.tag)-step1", in: conversation)
    try await waitForReply(hello, in: conversation)
    #expect(
      try await eventually(seconds: 60) {
        !conversation.isRunning && reply(hello, in: conversation)?.isStreaming == false
      }, "the turn did not end: \(state(of: conversation, reply: hello))")

    // Stop ends a slow reply before its end and marks it interrupted.
    let slow = "[\(live.tag)-slow]"
    try await send("Now take your time. \(live.tag)-step2", in: conversation)
    try await waitForReply(slow, in: conversation)
    await conversation.interrupt()
    #expect(conversation.errors.isEmpty, "\(conversation.errors)")
    #expect(
      try await eventually(seconds: 30) { reply(slow, in: conversation)?.interrupted == true },
      "the stopped reply was not marked interrupted: \(state(of: conversation, reply: slow))")
    let text = reply(slow, in: conversation)?.text ?? ""
    #expect(!text.contains("word120 word1 word2"), "the slow reply ran to its end")
  }

  private func send(_ text: String, in conversation: ConversationStore) async throws {
    conversation.composer.text = text
    await conversation.composer.send()
    if let error = conversation.composer.lastError {
      throw LiveServerError("sending \(text) failed: \(error)")
    }
  }

  /// Waits for a transcript row with `marker` (the mock prefixes each reply with one).
  private func waitForReply(_ marker: String, in conversation: ConversationStore) async throws {
    guard try await eventually(seconds: 60, { reply(marker, in: conversation) != nil }) else {
      throw LiveServerError("no reply \(marker): \(state(of: conversation, reply: marker))")
    }
  }

  /// The row with `marker`, looked up each time: a streamed reply's row can be replaced by the
  /// saved message's row when the turn ends.
  private func reply(_ marker: String, in conversation: ConversationStore) -> Row? {
    conversation.transcriptRows.last { $0.text.contains(marker) }
  }

  /// What the store shows, for failure messages.
  private func state(of conversation: ConversationStore, reply marker: String) -> String {
    let row = reply(marker, in: conversation)
    return "status \(String(describing: conversation.header?.status)), link \(conversation.link), "
      + "reply \(row.map { "\($0.id) streaming=\($0.isStreaming) interrupted=\($0.interrupted)" } ?? "none"), "
      + "errors \(conversation.errors), last failure \(conversation.lastFailure ?? "none")"
  }
}

/// The live server and session from the environment.
nonisolated struct LiveServer: Sendable {
  let url: String
  let sessionID: String
  let tag: String

  static let current: Self? = {
    let environment = ProcessInfo.processInfo.environment
    guard let url = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_SESSION_ID"]
    else { return nil }
    return Self(url: url, sessionID: sessionID, tag: environment["OMNIGENT_E2E_TAG"] ?? "run")
  }()
}

struct LiveServerError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Polls `condition` until it holds or `seconds` pass.
@MainActor
private func eventually(seconds: Int, _ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(50))
  }
  return condition()
}
