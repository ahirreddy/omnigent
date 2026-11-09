import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// One listed session, for reads that only need a row.
let singleSessionList = #"""
  {"object":"list","has_more":false,"data":[{"id":"conv_a","title":"A","status":"idle","created_at":1,"updated_at":2,"owner":"local","permission_level":4}]}
  """#

/// A performer answering with the bytes it was given.
@MainActor
private final class AnsweringPerformer: BrowserActionPerforming {
  let answer: Data

  init(answer: Data) { self.answer = answer }

  // swiftlint:disable:next async_without_await
  func perform(_ request: BrowserActionRequest) async throws -> Data { answer }
}

/// Canvas reads and the cap on saved spots.
@MainActor
@Suite("Canvas reads", .timeLimit(.minutes(1)))
struct CanvasLoadTests {
  private func positionsKey(_ key: String) -> String { "\(key).positions" }

  @Test("A first read that fails shows the failure; a later one keeps the cards on screen")
  func failures() async throws {
    let server = RouteServer()
    server.fail("/v1/sessions")
    let store = try await connectedStore(server)
    let canvas = try #require(store.canvas)
    await canvas.load(viewerID: "local")
    guard case .failed = canvas.sessions else {
      Issue.record("sessions: \(canvas.sessions)")
      return
    }

    server.route("/v1/sessions", .json(singleSessionList))
    await canvas.load(viewerID: "local")
    #expect(canvas.sessions.value?.map(\.id) == ["conv_a"])

    server.fail("/v1/sessions")
    await canvas.load(viewerID: "local")
    #expect(canvas.sessions.value?.map(\.id) == ["conv_a"])
    #expect(canvas.refreshError != nil)
    #expect(!canvas.isRefreshing)

    server.route("/v1/sessions", .json(singleSessionList))
    await canvas.load(viewerID: "local")
    #expect(canvas.refreshError == nil, "the next read that works clears it")
  }

  @Test("A reload says it's refreshing until it lands")
  func refreshing() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", .json(singleSessionList))
    let store = try await connectedStore(server)
    let canvas = try #require(store.canvas)
    await canvas.load(viewerID: "local")

    let gate = server.hold("/v1/sessions")
    async let reload: Void = canvas.load(viewerID: "local")
    try await eventually("the reload") { canvas.isRefreshing && gate.arrivals > 0 }
    gate.release()
    await reload
    #expect(!canvas.isRefreshing)
  }

  @Test("Saved spots stop at the cap, and listed sessions keep theirs")
  func capsSavedSpots() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", .json(singleSessionList))
    let core = try #require(try await connectedStore(server).core)
    let suite = "canvas-cap-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "server-a"
    var stored = [String: [Int]]()
    for index in 0...CanvasStore.maxSavedPositions { stored["old_\(index)"] = [0, 0] }
    defaults.set(stored, forKey: positionsKey(key))

    let canvas = CanvasStore(core: core, defaults: defaults)
    canvas.bind(key: key)
    await canvas.load(viewerID: "local")
    #expect(canvas.saved.count == CanvasStore.maxSavedPositions)
    #expect(canvas.saved["conv_a"] != nil)
    let persisted = defaults.dictionary(forKey: positionsKey(key))
    #expect(persisted?.count == CanvasStore.maxSavedPositions)
  }
}

/// Browser actions that don't get as far as the result.
@MainActor
@Suite("Browser action failures", .timeLimit(.minutes(1)))
struct BrowserActionFailureTests {
  private let claimPath = "/v1/sessions/conv_a/browser/action_claim/a1"
  private let request = BrowserActionRequest(
    sessionId: "conv_a", actionId: "a1", action: "navigate", argsJson: "{}")

  private func actions(_ server: RouteServer, answer: Data = Data("{}".utf8)) async throws
    -> BrowserActionStore
  {
    let store = try await connectedStore(server)
    let actions = try #require(store.browserActions)
    actions.performer = AnsweringPerformer(answer: answer)
    return actions
  }

  @Test("A claim that fails keeps the reason until it's dismissed, and nothing runs")
  func claimFails() async throws {
    let server = RouteServer()
    server.fail(claimPath, method: "POST", status: 403)
    let actions = try await actions(server)
    await actions.handle(request)
    #expect(actions.lastError != nil)
    actions.dismissError()
    #expect(actions.lastError == nil)
  }

  @Test("An engine answer that isn't text fails the action instead of posting garbage")
  func unreadableResult() async throws {
    let server = RouteServer()
    server.route(
      claimPath, method: "POST", .json(#"{"claimed":true,"claim_token":"tok_1"}"#))
    let actions = try await actions(server, answer: Data([0xFF, 0xFE]))
    await actions.handle(request)
    #expect(actions.lastError?.message.contains("not UTF-8") == true)
    #expect(server.requests(to: "/v1/sessions/conv_a/browser/action_result/a1").isEmpty)
  }

  @Test("A failure that can be written goes out as JSON; one that can't is an error")
  func failureJSON() throws {
    struct Unencodable: Encodable {
      func encode(to encoder: any Encoder) throws { throw CocoaError(.coderInvalidValue) }
    }
    let written = try BrowserActionStore.failureJSON(["ok": "no"]).get()
    #expect(written == #"{"ok":"no"}"#)
    guard case .failure(.InvalidState(let message)) = BrowserActionStore.failureJSON(Unencodable())
    else {
      Issue.record("expected the failure to be reported")
      return
    }
    #expect(message.contains("Could not encode"))
  }

  @Test("A browser action event reaches the handler; with none it's left for another client")
  func eventsReachTheHandler() async throws {
    let server = RouteServer()
    server.route(claimPath, method: "POST", .json(#"{"claimed":false}"#))
    let store = try await connectedStore(server)
    let actions = try #require(store.browserActions)
    actions.performer = AnsweringPerformer(answer: Data("{}".utf8))
    store.apply(
      .browserActionRequested(
        sessionId: "conv_a", actionId: "a1", action: "navigate", argsJson: "{}"))
    try await eventually("the claim") { !server.requests(to: claimPath).isEmpty }
  }
}
