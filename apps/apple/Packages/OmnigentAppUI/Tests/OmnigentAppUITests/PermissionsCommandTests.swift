import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// `/permissions` typed and sent in a Codex conversation's own composer, over a server that
/// records what the window then asks of it.
@MainActor
@Suite("Conversation: the /permissions command", .serialized, .timeLimit(.minutes(1)))
struct PermissionsCommandTests {
  private typealias Screen = OffscreenWindow<AppWindowRoot>
  private static let path = "/v1/sessions/conv_a"
  private static let codexSession = """
    {"id":"conv_a","status":"idle","created_at":1,"updated_at":30,"host_id":"mac",\
    "workspace":"/work/conv_a","permission_level":4,"harness":"codex-native",\
    "agent_id":"ag_codex","labels":{"omnigent.wrapper":"codex-native-ui"},\
    "host_online":true,"runner_online":true}
    """

  init() {
    SystemSideEffects.install()
    SystemSideEffects.reset()
  }

  /// The window on a Codex session that has read its history and its approval modes, with the
  /// keyboard in its composer.
  private func codexWindow() async throws -> CodexWindow {
    let server = threeSessionServer()
    server.route(Self.path, .json(Self.codexSession))
    server.route(Self.path, method: "PATCH", .json(Self.codexSession))
    server.route("\(Self.path)/items", .json(#"{"data":[],"has_more":false}"#))
    let streams = FakeEventStreamTransport()
    let connection = try await signedInStore(server, streams: streams)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let session = ServerSession(connection: connection, opener: ExternalURLOpener { _ in true })
    session.tabs.show(.session("conv_a"))
    session.keepOpen(session.tabs.liveSessionIDs)
    let conversation = try #require(connection.openConversation("conv_a"))
    // The connection's own update stream may open first.
    var opened = await streams.waitForOpenedStream()
    while !opened.request.url.contains("\(Self.path)/stream") {
      opened = await streams.waitForOpenedStream()
    }
    opened.sink.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    // The first frame on the stream makes the core read the session's history.
    let heartbeat = #"event: session.heartbeat\#ndata: {"type":"session.heartbeat"}\#n\#n"#
    opened.sink.chunk(bytes: Data(heartbeat.utf8))
    try await eventually("the session to hydrate") { conversation.isHydrated }

    let screen = OffscreenWindow(
      AppWindowRoot(session: session, selection: WindowSelection(.session("conv_a"))),
      width: 1200, height: 800)
    try await pause(screen, .milliseconds(300))
    let composer = conversation.composer
    try await settle(screen, until: "the session's approval modes") {
      composer.approvalModeMenu != nil
    }
    try await settle(screen, until: "the composer to take the keyboard") {
      screen.window.firstResponder is NSTextView
    }
    return CodexWindow(screen: screen, server: server, composer: composer)
  }

  private struct CodexWindow {
    let screen: Screen
    let server: AppServer
    let composer: ComposerStore
  }

  /// Types the command and presses Return until the composer takes it: the first Return fills
  /// in the suggestion the command menu highlights.
  private func sendPermissions(_ screen: Screen, _ composer: ComposerStore) async throws {
    try screen.type("/permissions")
    try await settle(screen, until: "the keys") { composer.text == "/permissions" }
    #expect(composer.text == "/permissions", "the keys reach the composer")
    for _ in 0..<2 where composer.approvalPickerRequests == 0 {
      try screen.press(keyCode: 36, characters: "\r")
      _ = await screen.waitUntil(timeout: .milliseconds(200)) {
        composer.approvalPickerRequests > 0
      }
    }
    #expect(composer.approvalPickerRequests == 1)
    try await settle(screen, until: "the approval dialog") {
      !SystemSideEffects.record.alertMessages.isEmpty
    }
  }

  @Test("Typed and sent, it asks which mode and sends the answer to the server")
  func asksAndSwitches() async throws {
    let window = try await codexWindow()
    let (screen, server, composer) = (window.screen, window.server, window.composer)
    defer { screen.close() }
    try await sendPermissions(screen, composer)
    #expect(SystemSideEffects.record.alertMessages.count == 1)
    #expect(composer.text.isEmpty, "the command leaves the field")
    try await settle(screen, until: "the mode's request") {
      !server.requests("PATCH", Self.path).isEmpty
    }
    #expect(server.requests("PATCH", Self.path).count == 1)
  }

  @Test("Cancel in its dialog sends the server nothing")
  func cancelSwitchesNothing() async throws {
    let window = try await codexWindow()
    let (screen, server, composer) = (window.screen, window.server, window.composer)
    defer { screen.close() }
    let modes = try #require(composer.approvalModeMenu).options.count { $0.switchable }
    // The dialog's buttons: one per mode Codex can switch to, then Cancel.
    let cancel = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + modes
    SystemSideEffects.answer(
      alert: NSApplication.ModalResponse(rawValue: cancel), for: screen.window)
    try await sendPermissions(screen, composer)
    try await pause(screen, .milliseconds(300))
    #expect(SystemSideEffects.record.alertMessages.count == 1)
    #expect(server.requests("PATCH", Self.path).isEmpty)
  }
}
