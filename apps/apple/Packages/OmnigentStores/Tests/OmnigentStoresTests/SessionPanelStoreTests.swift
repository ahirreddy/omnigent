import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// A loopback server whose `/v1/info` adds the `info` fields and whose pull-request route
/// answers `pullRequests`, recording every read.
nonisolated private final class PanelServer: Sendable {
  let info: String
  let pullRequests: HttpResponse
  let reads = Mutex<[String]>([])

  init(info: String, pullRequests: HttpResponse) {
    self.info = info
    self.pullRequests = pullRequests
  }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    reads.withLock { $0.append(path) }
    switch path {
    case "/.well-known/omnigent.json": return .json(ManifestFixtures.localNoAuth)
    case "/v1/info": return .json(#"{"single_user":true,"accounts_enabled":false,\#(info)}"#)
    case "/v1/me": return .json(#"{"user_id":"local"}"#)
    case "/v1/sessions": return .json(#"{"data":[],"has_more":false}"#)
    case "/v1/sessions/conv_a/pull-requests": return pullRequests
    default: return .json(#"{"detail":"not found"}"#, status: 404)
    }
  }

  func count(_ path: String) -> Int {
    reads.withLock { $0.filter { $0 == path }.count }
  }
}

@MainActor
private func connectedPanelStore(_ server: PanelServer) async throws -> SessionPanelStore {
  let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
  let core = try ClientCore(
    http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
    clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  let connection = ConnectionStore(core: core)
  await connection.connect(serverURL: "http://127.0.0.1:6767")
  #expect(connection.isSignedIn, "phase: \(connection.phase)")
  return try #require(connection.makePanelStore("conv_a"))
}

private let pullRequestsPath = "/v1/sessions/conv_a/pull-requests"

private let onePullRequest = HttpResponse.json(
  #"""
  {"object":"list","data":[{"url":"https://github.com/o/r/pull/7","host":"github.com",
   "repository":"o/r","number":7,"title":"Fix login","relationship":"created",
   "state":"MERGED"}],"has_more":false,"synced":true}
  """#)

@MainActor
struct SessionPanelStoreTests {
  @Test func readsFeaturesOnceAndThenThePullRequests() async throws {
    let server = PanelServer(
      info: #""session_pull_requests":true,"features":{"workspace_content_search":true}"#,
      pullRequests: onePullRequest)
    let store = try await connectedPanelStore(server)
    let infoReads = server.count("/v1/info")

    await store.reloadPullRequests()
    await store.reloadPullRequests()

    #expect(store.offersContentSearch)
    let list = try #require(store.pullRequests.value)
    #expect(list.synced)
    #expect(list.pullRequests.map(\.number) == [7])
    #expect(list.pullRequests.first?.status == .merged)
    #expect(server.count("/v1/info") == infoReads + 1, "the features are read once")
    #expect(server.count(pullRequestsPath) == 2)
  }

  @Test func anOlderServerIsNeverAskedForPullRequests() async throws {
    let server = PanelServer(info: #""dictation_available":false"#, pullRequests: onePullRequest)
    let store = try await connectedPanelStore(server)

    await store.reloadPullRequests()

    #expect(!store.offersPullRequests && !store.offersContentSearch)
    #expect(store.features != nil)
    #expect(store.pullRequests == .idle)
    #expect(server.count(pullRequestsPath) == 0)
  }

  @Test func aFailedReadIsKept() async throws {
    let server = PanelServer(
      info: #""session_pull_requests":true"#,
      pullRequests: .json(#"{"detail":"Session not found"}"#, status: 404))
    let store = try await connectedPanelStore(server)

    await store.reloadPullRequests()

    guard case .failed = store.pullRequests else {
      Issue.record("expected a failure, got \(store.pullRequests)")
      return
    }
  }
}
