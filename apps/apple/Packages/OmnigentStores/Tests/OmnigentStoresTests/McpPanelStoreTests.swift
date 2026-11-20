import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// A loopback server for one claude-sdk session's `/mcp` sources and its reconnects.
nonisolated private final class McpServer: Sendable {
  let reconnects = Mutex<[HttpResponse]>([])

  func respond(_ request: HttpRequest) -> HttpResponse {
    switch URLComponents(string: request.url)?.path ?? "" {
    case "/.well-known/omnigent.json": return .json(ManifestFixtures.localNoAuth)
    case "/v1/info": return .json(#"{"single_user":true,"accounts_enabled":false}"#)
    case "/v1/me": return .json(#"{"user_id":"local"}"#)
    case "/v1/sessions": return .json(#"{"data":[],"has_more":false}"#)
    case "/v1/sessions/conv_a/live-mcp-servers":
      return .json(#"{"live":true,"servers":[{"name":"docs","status":"failed","error":"exit 1"}]}"#)
    case "/v1/sessions/conv_a/live-mcp-servers/reconnect":
      return reconnects.withLock { $0.isEmpty ? .json("{}", status: 500) : $0.removeFirst() }
    default: return .json(#"{"detail":"not found"}"#, status: 404)
    }
  }
}

@MainActor
private func connectedPanel(_ server: McpServer) async throws -> McpPanelStore {
  let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
  let core = try ClientCore(
    http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
    clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  let connection = ConnectionStore(core: core)
  await connection.connect(serverURL: "http://127.0.0.1:6767")
  #expect(connection.isSignedIn, "phase: \(connection.phase)")
  let store = McpPanelStore(sessionID: "conv_a", core: core)
  store.session = {
    var session = McpPanelStore.Session()
    session.harness = "claude-sdk"
    return session
  }
  return store
}

@MainActor
@Suite("The /mcp panel's store", .timeLimit(.minutes(1)))
struct McpPanelStoreTests {
  @Test func aSettledPanelIsReadOnceAndAReconnectSaysWhyItFailed() async throws {
    let server = McpServer()
    server.reconnects.withLock {
      $0 = [
        .json(#"{"live":true,"servers":[],"reconnect_error":"token expired"}"#),
        .json(#"{"error":{"message":"This session's agent isn't running yet."}}"#, status: 409),
      ]
    }
    let store = try await connectedPanel(server)

    await store.watch()
    #expect(store.panel?.rows.map(\.name) == ["docs"])
    #expect(store.panel?.rows.first?.live?.error == "exit 1")

    await store.reconnect("docs")
    #expect(store.reconnectFailure?.message == "token expired")
    #expect(store.reconnecting == nil)
    await store.reconnect("docs")
    #expect(store.reconnectFailure?.message.contains("running yet") == true)
  }
}
