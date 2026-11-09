import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A Codex session offering two models, both with two efforts.
let codexFields = #"""
  "harness":"codex-native","agent_id":"clone","labels":{"omnigent.wrapper":"codex-native-ui"},
  "reasoning_effort":"high","model_override":"sample-balanced","host_id":"demo-host",
  "host_online":true,"runner_online":true,"model_options":[
  {"id":"sample-balanced","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"high"},{"reasoningEffort":"low"}]},
  {"id":"sample-fast","supportedReasoningEfforts":[{"reasoningEffort":"high"},{"reasoningEffort":"low"}]}]
  """#

/// The snapshot of a session, with `fields`.
func snapshot(_ fields: String) -> HttpResponse {
  .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,\#(fields)}"#)
}

/// A Claude session in approval mode `mode`.
func claudeFields(_ mode: String) -> String {
  #"""
  "harness":"claude-native","agent_id":"claude","host_id":"demo-host","host_online":true,
  "runner_online":true,"labels":{"omnigent.wrapper":"claude-code-native-ui",
  "omnigent.claude_native.permission_mode":"\#(mode)"}
  """#
}

/// A session the composer can send to: writable, and its live stream hydrated.
@MainActor
struct LiveComposer {
  let server: RouteServer
  let store: ConnectionStore
  let conversation: ConversationStore
  var composer: ComposerStore { conversation.composer }

  // `fields` are JSON fields added to the session's snapshot, `""` for none.
  init(server: RouteServer = RouteServer(), fields: String = "") async throws {
    self.server = server
    let extra = fields.isEmpty ? "" : ",\(fields)"
    server.route(
      "/v1/sessions/conv_a", method: "GET",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4\#(extra)}"#))
    server.route("/v1/sessions/conv_a/items", .json(#"{"data":[],"has_more":false}"#))
    let streams = FakeEventStreamTransport()
    store = try await connectedStore(server, streams: streams)
    conversation = try #require(store.conversation("conv_a"))
    let opened = await streams.waitForOpenedStream()
    opened.sink.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    // The first frame on the stream makes the core read the session's history.
    let heartbeat = #"event: session.heartbeat\#ndata: {"type":"session.heartbeat"}\#n\#n"#
    opened.sink.chunk(bytes: Data(heartbeat.utf8))
    let conversation = self.conversation
    try await eventually("the session to hydrate") { conversation.isHydrated }
  }

  /// Waits out the rereads a write triggers: one that crosses a settings read would look like
  /// the settings changing elsewhere.
  func settle() async throws {
    var last = -1
    var stable = 0
    while stable < 3 {
      try await Task.sleep(for: .milliseconds(15))
      stable = store.eventsApplied == last ? stable + 1 : 0
      last = store.eventsApplied
    }
  }

  /// Answers message posts as accepted from now on.
  func acceptMessages() {
    server.route("/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":true}"#))
  }

  /// Refuses message posts because the session's host is offline.
  func hostIsOffline() {
    server.route(
      "/v1/sessions/conv_a/events", method: "POST",
      .json(#"{"error":{"code":"host_offline","message":"The host is offline."}}"#, status: 503))
  }

  /// Every message text posted so far, in order.
  var postedTexts: [String] {
    server.requests(to: "/v1/sessions/conv_a/events", method: "POST").compactMap { request in
      guard let body = try? server.body(of: request), let data = body["data"] as? [String: Any],
        let content = data["content"] as? [[String: Any]]
      else { return nil }
      return content.compactMap { $0["text"] as? String }.joined()
    }
  }
}
