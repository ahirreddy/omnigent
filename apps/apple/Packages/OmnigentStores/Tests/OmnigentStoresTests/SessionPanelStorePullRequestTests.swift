import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import OmnigentWorkspaceUI
import Synchronization
import Testing

@testable import OmnigentStores

nonisolated private let prURL = "https://github.com/o/r/pull/7"
nonisolated private let githubPath = "/v1/sessions/conv_a/resources/github"

nonisolated private let linkedList = #"""
  {"object":"list","data":[{"url":"https://github.com/o/r/pull/7","host":"github.com",
   "repository":"o/r","number":7,"title":"Fix","relationship":"created","state":"OPEN"}],
   "has_more":false,"synced":true}
  """#

nonisolated private let info = #"""
  {"object":"session.github.info","available":true,"branch":"fix","repo":{"name_with_owner":"o/r"},
   "auth":{"authenticated":true},"capabilities":{"label_editing":true,"merging":true},
   "selected_pr_url":"https://github.com/o/r/pull/7","tracking_available":true,
   "prs":[{"url":"https://github.com/o/r/pull/7","host":"github.com","repository":"o/r",
           "number":7,"relationship":"created","state":"OPEN"}],
   "pr":{"number":7,"title":"Fix","state":"OPEN","url":"https://github.com/o/r/pull/7",
         "head_sha":"abc","checks":{"failing":1,"total":1},"labels":[],"merge_state_status":"CLEAN"}}
  """#

nonisolated private let patch = #"""
  {"object":"session.github.pr_diff","patch":"diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"}
  """#

/// A loopback server for the pull request routes; records each request's method, path and body.
nonisolated private struct Recorded: Sendable {
  let method: String
  let path: String
  let body: String
}

nonisolated private final class PullRequestServer: Sendable {
  let requests = Mutex<[Recorded]>([])
  let mergeAnswer: HttpResponse

  init(mergeAnswer: HttpResponse = .json("{}")) {
    self.mergeAnswer = mergeAnswer
  }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    let body = request.body.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    requests.withLock { $0.append(Recorded(method: request.method, path: path, body: body)) }
    switch (request.method, path) {
    case (_, "/.well-known/omnigent.json"): return .json(ManifestFixtures.localNoAuth)
    case (_, "/v1/info"):
      return .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#)
    case (_, "/v1/me"): return .json(#"{"user_id":"local"}"#)
    case (_, "/v1/sessions"): return .json(#"{"data":[],"has_more":false}"#)
    case (_, "/v1/sessions/conv_a/pull-requests"): return .json(linkedList)
    case ("GET", githubPath), ("POST", "\(githubPath)/prs"): return .json(info)
    case ("GET", "\(githubPath)/diff"): return .json(patch)
    case ("POST", "\(githubPath)/labels"):
      return .json(#"{"labels":[{"name":"bug","color":"d73a4a"}]}"#)
    case ("POST", "\(githubPath)/merge"): return mergeAnswer
    default: return .json(#"{"detail":"not found"}"#, status: 404)
    }
  }

  func bodies(_ method: String, _ path: String) -> [String] {
    requests.withLock { $0.filter { $0.method == method && $0.path == path }.map(\.body) }
  }
}

@MainActor
private func connectedStore(_ server: PullRequestServer) async throws -> SessionPanelStore {
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

@MainActor
struct SessionPanelStorePullRequestTests {
  @Test func showingAPullRequestReadsItsDetailAndFiles() async throws {
    let server = PullRequestServer()
    let store = try await connectedStore(server)

    await store.showPullRequest(prURL)

    #expect(store.openPullRequest == prURL)
    let detail = try #require(store.detail.value?.pullRequest)
    #expect(detail.condition == .checksFailing)
    let files = try #require(store.files.value)
    #expect(files.files.map(\.path) == ["a.txt"])
    #expect(store.liveConditions[prURL] == .checksFailing)

    store.showPullRequestList()
    #expect(store.openPullRequest == nil && store.detail == .idle)
  }

  @Test func theListReadsEachOpenPullRequestsLiveCondition() async throws {
    let server = PullRequestServer()
    let store = try await connectedStore(server)

    await store.reloadPullRequests()

    #expect(store.liveConditions == [prURL: .checksFailing])
  }

  @Test func editsUpdateTheShownDetail() async throws {
    let server = PullRequestServer()
    let store = try await connectedStore(server)
    await store.showPullRequest(prURL)

    await store.setLabel("bug", added: true)

    #expect(store.detail.value?.pullRequest?.labels?.map(\.name) == ["bug"])
    #expect(store.pendingEdit == nil && store.editError == nil)
    let body = try #require(server.bodies("POST", "\(githubPath)/labels").first)
    #expect(body.contains(#""add":["bug"]"#))
  }

  @Test func linkingShowsTheLinkedPullRequest() async throws {
    let server = PullRequestServer()
    let store = try await connectedStore(server)

    let linked = await store.linkPullRequest(prURL)

    #expect(linked)
    #expect(store.openPullRequest == prURL)
    #expect(store.pullRequests.value?.pullRequests.count == 1)
    #expect(
      server.bodies("POST", "\(githubPath)/prs").first?.contains(#""action":"attach""#) == true)
  }

  @Test func aRefusedMergeKeepsTheHostsReason() async throws {
    let server = PullRequestServer(
      mergeAnswer: .json(#"{"detail":"Resolve conflicts first."}"#, status: 400))
    let store = try await connectedStore(server)
    await store.showPullRequest(prURL)

    let merged = await store.mergePullRequest(.squash)

    #expect(!merged)
    #expect(store.editError?.message == "Resolve conflicts first.")
    let body = try #require(server.bodies("POST", "\(githubPath)/merge").first)
    #expect(body.contains(#""expected_head":"abc""#))
  }
}
