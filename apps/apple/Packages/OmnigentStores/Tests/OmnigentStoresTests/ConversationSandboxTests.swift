import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
@Suite("A sandbox session's operations", .timeLimit(.minutes(1)))
struct ConversationSandboxTests {
  private let sessionPath = "/v1/sessions/conv_a"
  private let eventsPath = "/v1/sessions/conv_a/events"
  private let owned =
    #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"host_id":"sbx","host_online":false,"runner_online":false,"host_resumable":true}"#

  private func conversation(_ server: RouteServer) async throws -> ConversationStore {
    server.route(sessionPath, method: "GET", .json(owned))
    let store = try await connectedStore(server)
    return try #require(store.conversation("conv_a"))
  }

  private func posted(_ server: RouteServer) throws -> [String] {
    try server.requests(to: eventsPath, method: "POST").map { request in
      let body = try #require(request.body)
      let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
      return object["type"] as? String ?? ""
    }
  }

  @Test("Wake asks the server to bring the session back, once, and says what it did")
  func wake() async throws {
    let server = RouteServer()
    server.route(
      eventsPath, method: "POST",
      .json(#"{"queued":false,"recovered":true,"recovery":"runner_relaunched"}"#, status: 202))
    let conversation = try await conversation(server)
    #expect(try await conversation.performSandboxOperation(.wake) == .started)
    #expect(try posted(server) == ["retry_session"])

    server.route(
      eventsPath, method: "POST",
      .json(#"{"queued":false,"recovered":false,"recovery":"already_connected"}"#, status: 202))
    #expect(try await conversation.performSandboxOperation(.wake) == .alreadyRunning)
    #expect(try posted(server) == ["retry_session", "retry_session"])
  }

  @Test("Stop asks the server to end the agent, once")
  func stop() async throws {
    let server = RouteServer()
    server.route(eventsPath, method: "POST", .json(#"{"queued":false}"#, status: 202))
    let conversation = try await conversation(server)
    #expect(try await conversation.performSandboxOperation(.stop) == .stopped)
    #expect(try posted(server) == ["stop_session"])
  }

  @Test(
    "What the server refuses comes back with its reason, and is not asked again",
    arguments: [SandboxOperation.wake, .stop])
  func refused(operation: SandboxOperation) async throws {
    let server = RouteServer()
    server.route(
      eventsPath, method: "POST",
      .json(
        #"{"error":{"code":"runner_unavailable","message":"No runner is available to recover this session."}}"#,
        status: 503))
    let conversation = try await conversation(server)
    let failure = await #expect(throws: CoreError.self) {
      try await conversation.performSandboxOperation(operation)
    }
    let message = failure?.message ?? ""
    #expect(message.contains("No runner is available to recover this session."), "\(message)")
    #expect(try posted(server).count == 1)
  }
}
