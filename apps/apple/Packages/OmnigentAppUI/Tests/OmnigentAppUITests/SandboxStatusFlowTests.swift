import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The sandbox control's state and operations through the real stores: a recording server
/// answers the reads and takes the requests, and its stream delivers the status events.
@MainActor
@Suite("Sandbox status: through the stores", .serialized, .timeLimit(.minutes(1)))
struct SandboxStatusFlowTests {
  private static let path = "/v1/sessions/conv_a"
  private static let events = "/v1/sessions/conv_a/events"
  private static let launching =
    #""host_id":null,"runner_id":null,"runner_online":false,"sandbox_status":{"stage":"provisioning","provider":"modal"}"#
  private static let asleep =
    #""host_id":"sbx","runner_id":"r1","host_online":false,"runner_online":false,"host_resumable":true,"sandbox_status":null"#
  private static let running =
    #""host_id":"sbx","runner_id":"r1","host_online":true,"runner_online":true,"host_resumable":true,"sandbox_status":null"#

  /// The owner's session `conv_a` on a native harness, reporting `fields` besides.
  private static func session(_ fields: String) -> String {
    #"{"id":"conv_a","status":"idle","created_at":1,"updated_at":30,"permission_level":4,"harness":"codex-native","agent_id":"ag_codex",\#(fields)}"#
  }

  private struct Opened {
    let server: AppServer
    let connection: ConnectionStore
    let conversation: ConversationStore
    let sink: ByteSink

    /// The control's state, with the host list the connection read.
    @MainActor var sandbox: SandboxStatusState? {
      let list = connection.sessionList
      return SandboxAdapter.state(conversation) { list.hostEnvironments[$0] }
    }

    /// The server now reports `fields` for the session, and says so on its stream.
    @MainActor
    func report(_ fields: String, stage: String, error: String? = nil) {
      server.route(SandboxStatusFlowTests.path, .json(SandboxStatusFlowTests.session(fields)))
      let failure = error.map { #","error":"\#($0)""# } ?? ""
      let event =
        #"{"type":"session.sandbox_status","conversation_id":"conv_a","stage":"\#(stage)","provider":"modal"\#(failure)}"#
      sink.chunk(bytes: Data("event: session.sandbox_status\ndata: \(event)\n\n".utf8))
    }

    /// The types of the events the app posted.
    func posted() throws -> [String] {
      try server.posted(SandboxStatusFlowTests.events).map { $0["type"] as? String ?? "" }
    }
  }

  /// Opens `conv_a` on a server whose host `sbx` is a Modal sandbox, with its stream attached
  /// and its history read.
  private func opened(_ fields: String) async throws -> Opened {
    let server = AppServer()
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"sbx","name":"managed-1","status":"online","sandbox_provider":"modal"}]}"#
      ))
    let row = Self.session(fields)
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    server.route(Self.path, .json(row))
    server.route("\(Self.path)/items", .json(#"{"data":[],"has_more":false}"#))
    let streams = FakeEventStreamTransport()
    let connection = try await signedInStore(server, streams: streams)
    try await eventually("the session list") { connection.sessionList.session("conv_a") != nil }
    try await eventually("the hosts") { connection.sessionList.hostEnvironments["sbx"] != nil }
    let conversation = try #require(connection.conversation("conv_a"))
    // The connection's own update stream may open first.
    var stream = await streams.waitForOpenedStream()
    while !stream.request.url.contains("\(Self.path)/stream") {
      stream = await streams.waitForOpenedStream()
    }
    stream.sink.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    // The first frame on the stream makes the core read the session.
    let heartbeat = #"event: session.heartbeat\#ndata: {"type":"session.heartbeat"}\#n\#n"#
    stream.sink.chunk(bytes: Data(heartbeat.utf8))
    try await eventually("the session to hydrate") { conversation.isHydrated }
    return Opened(
      server: server, connection: connection, conversation: conversation, sink: stream.sink)
  }

  private func row(_ opened: Opened) -> SessionRowInfo? {
    SidebarAdapter.row("conv_a", list: opened.connection.sessionList, showsDraft: false)?.info
  }

  @Test("A launch shows stage by stage as the server reports it, then the sandbox runs")
  func launchFollowsTheServer() async throws {
    let opened = try await opened(Self.launching)
    let first = try #require(opened.sandbox)
    #expect(first.mark == .progress)
    #expect(first.title == "Modal Sandbox")
    #expect(first.statusLine == "Provisioning sandbox\u{2026}")
    #expect(first.operations.map(\.unavailableReason).allSatisfy { $0 != nil })
    #expect(
      LivenessAdapter.notice(opened.conversation, serverURL: nil)?.line
        == "Provisioning sandbox\u{2026}")
    try await eventually("the row's stage") {
      row(opened)?.environment == "Provisioning sandbox"
    }
    #expect(row(opened)?.isDisconnected == false)

    let cloning =
      #""host_id":null,"runner_id":null,"runner_online":false,"sandbox_status":{"stage":"cloning","provider":"modal"}"#
    opened.report(cloning, stage: "cloning")
    try await eventually("the cloning stage") { opened.sandbox?.summary == "Cloning repository" }
    // The row learns the stage from the read the event asked for.
    try await eventually("the row's stage") { row(opened)?.environment == "Cloning repository" }

    let failed =
      #""host_id":null,"runner_id":null,"runner_online":false,"sandbox_status":{"stage":"failed","provider":"modal","error":"No capacity"}"#
    opened.report(failed, stage: "failed", error: "No capacity")
    try await eventually("the failure") { opened.sandbox?.mark == .failed }
    #expect(opened.sandbox?.error == "No capacity")
    #expect(
      LivenessAdapter.notice(opened.conversation, serverURL: nil)?.failedLaunch?.line
        == "Sandbox launch failed: No capacity")
    try await eventually("the row's failure") {
      row(opened)?.disconnectedLabel == "Sandbox launch failed: No capacity"
    }
    #expect(row(opened)?.environment == "Sandbox launch failed")

    opened.report(Self.running, stage: "ready")
    try await eventually("the sandbox to run") { opened.sandbox?.mark == .running }
    let last = try #require(opened.sandbox)
    #expect(last.summary == "Running")
    #expect(last.host == .online && last.runner == .online)
    #expect(last.operations.map(\.unavailableReason) == ["The sandbox is already running.", nil])
    #expect(LivenessAdapter.notice(opened.conversation, serverURL: nil) == nil)
    try await eventually("the row to settle") { row(opened)?.environment == "Modal Sandbox" }
    #expect(row(opened)?.isDisconnected == false)
  }

  @Test("Wake sends one retry and Stop one stop; the state shown follows the server's status")
  func operations() async throws {
    let opened = try await opened(Self.asleep)
    let resting = try #require(opened.sandbox)
    #expect(resting.mark == .resting)
    #expect(resting.summary == "Asleep")
    #expect(resting.operations.map(\.title) == ["Wake", "Stop Agent"])
    #expect(resting.operations.map(\.unavailableReason) == [nil, "The agent is not running."])

    let perform = try #require(SandboxAdapter.actions(opened.conversation).perform)
    opened.server.route(
      Self.events, method: "POST",
      .json(#"{"queued":false,"recovered":true,"recovery":"runner_relaunched"}"#, status: 202))
    #expect(await perform("wake") == nil)
    #expect(try opened.posted() == ["retry_session"])

    // The server resumes the sandbox and says so; the control follows it.
    let waking =
      #""host_id":"sbx","runner_id":"r1","host_online":false,"runner_online":false,"host_resumable":true,"sandbox_status":{"stage":"starting","provider":"modal"}"#
    opened.report(waking, stage: "starting")
    try await eventually("the wake") { opened.sandbox?.statusLine == "Connecting host\u{2026}" }
    #expect(opened.sandbox?.mark == .progress)
    opened.report(Self.running, stage: "ready")
    try await eventually("the sandbox to run") { opened.sandbox?.mark == .running }

    opened.server.route(Self.events, method: "POST", .json(#"{"queued":false}"#, status: 202))
    #expect(await perform("stop") == nil)
    #expect(try opened.posted() == ["retry_session", "stop_session"])
  }

  @Test("What the server refuses comes back as its reason, asked once")
  func refusals() async throws {
    let opened = try await opened(Self.asleep)
    let perform = try #require(SandboxAdapter.actions(opened.conversation).perform)
    opened.server.route(
      Self.events, method: "POST",
      .json(
        #"{"error":{"code":"runner_unavailable","message":"No runner is available to recover this session."}}"#,
        status: 503))
    let refused = await perform("wake")
    #expect(refused?.contains("No runner is available") == true, "\(refused ?? "nil")")
    #expect(try opened.posted() == ["retry_session"])

    opened.server.route(
      Self.events, method: "POST",
      .json(#"{"queued":false,"recovered":false,"recovery":"already_connected"}"#, status: 202))
    #expect(await perform("wake") == "The agent is already connected.")

    opened.server.route(
      Self.events, method: "POST",
      .json(#"{"detail":"Only the owner can stop this session."}"#, status: 403))
    let forbidden = await perform("stop")
    #expect(forbidden != nil)
    #expect(try opened.posted() == ["retry_session", "retry_session", "stop_session"])
  }

  @Test("The conversation hands the control its state and its operations")
  func containerWiring() async throws {
    let settings = OmnigentCoreFFI.SessionSettings(
      agentId: "agent", harness: "codex-native", wrapper: nil, modelOverride: .notReported,
      baseModel: nil, reasoningEffort: .notReported, modelOptions: [], hostId: "host",
      hostOnline: false, runnerOnline: false, runnerBound: true, hostResumable: true,
      parentId: nil, sideChatSourceId: nil, routingMode: nil)
    let wired = try await ConversationWiringTests().wired(settings: settings)
    let sandbox = try #require(wired.container.state.sandbox)
    #expect(sandbox.summary == "Asleep")
    wired.server.route(
      "/v1/sessions/conv_a/events", method: "POST",
      .json(#"{"queued":false,"recovered":true,"recovery":"runner_relaunched"}"#, status: 202))
    let perform = try #require(wired.container.sandboxActions.perform)
    #expect(await perform("wake") == nil)
    #expect(try wired.server.posted("/v1/sessions/conv_a/events").count == 1)
  }
}
