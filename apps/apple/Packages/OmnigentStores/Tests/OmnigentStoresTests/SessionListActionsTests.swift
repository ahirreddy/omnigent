import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// A loopback single-user server answering by method and path, then by path.
nonisolated private final class ListServer: Sendable {
  private let routes = Mutex<[String: HttpResponse]>([:])
  private let requests = Mutex<[String]>([])

  init() {
    route("/.well-known/omnigent.json", .json(ManifestFixtures.localNoAuth))
    route("/v1/info", .json(#"{"single_user":true,"accounts_enabled":false}"#))
    route("/v1/me", .json(#"{"user_id":"local"}"#))
    route(
      "/v1/sessions",
      .json(
        #"{"object":"list","data":[{"id":"conv_a","status":"idle","created_at":1,"owner":"local","permission_level":4},{"id":"conv_b","status":"idle","created_at":1,"owner":"someone","permission_level":1}],"has_more":false}"#
      ))
    route("/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
  }

  func route(_ path: String, method: String? = nil, _ response: HttpResponse) {
    routes.withLock { $0[(method.map { "\($0) " } ?? "") + path] = response }
  }

  var writes: [String] { requests.withLock { $0 } }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    if request.method != "GET" { requests.withLock { $0.append("\(request.method) \(path)") } }
    return routes.withLock { $0["\(request.method) \(path)"] ?? $0[path] }
      ?? .json(#"{"detail":"not found"}"#, status: 404)
  }
}

@MainActor
struct SessionListActionsTests {
  private func connected(_ server: ListServer) async throws -> ConnectionStore {
    let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
    let core = try ClientCore(
      http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let store = ConnectionStore(core: core)
    await store.connect(serverURL: "http://127.0.0.1:6767")
    #expect(store.isSignedIn, "phase: \(store.phase)")
    let deadline = ContinuousClock.now + .seconds(10)
    while store.sessionList.projects.isEmpty || !store.sessionList.isLoaded,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    return store
  }

  @Test(.timeLimit(.minutes(1)))
  func projectsOwnershipAndMoving() async throws {
    let server = ListServer()
    server.route(
      "/v1/sessions/conv_a", method: "GET",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#))
    server.route(
      "/v1/sessions/conv_a", method: "PATCH",
      .json(
        #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"project_id":"p1"}"#))
    let store = try await connected(server)
    let list = store.sessionList
    #expect(list.viewerID == "local")
    #expect(list.projects.map(\.name) == ["Alpha"])
    let mine = try #require(list.session("conv_a"))
    let theirs = try #require(list.session("conv_b"))
    #expect(list.isOwned(mine))
    #expect(!list.isOwned(theirs))

    #expect(await list.move("conv_a", to: list.projects[0]))
    #expect(list.session("conv_a")?.projectId == "p1")
    #expect(list.members(of: list.visible) == [["conv_a"]])
  }

  @Test(.timeLimit(.minutes(1)))
  func projectOrderAndHostEnvironments() async throws {
    let server = ListServer()
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"mac","name":"Mac","status":"online"},{"host_id":"box","name":"Box","status":"online","sandbox_provider":"modal"}]}"#
      ))
    server.route(
      "/v1/projects/order", method: "PUT",
      .json(#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#))
    let store = try await connected(server)
    let list = store.sessionList
    await list.loadHosts(serverURL: "http://127.0.0.1:6767")
    #expect(
      list.hostEnvironments == ["mac": .thisMachine, "box": .sandbox(label: "Modal Sandbox")])
    #expect(list.hostsError == nil)

    #expect(await list.saveProjectOrder(list.projects))
    #expect(server.writes.contains("PUT /v1/projects/order"))
  }

  @Test(.timeLimit(.minutes(1)))
  func projectSortModeAndIcon() async throws {
    let server = ListServer()
    server.route(
      "/v1/projects/order", method: "GET",
      .json(#"{"sort_mode":"manual","ordered_project_ids":["p1"]}"#))
    server.route(
      "/v1/projects/order", method: "PUT",
      .json(#"{"sort_mode":"alphabetical","ordered_project_ids":null}"#))
    server.route(
      "/v1/projects/p1", method: "GET",
      .json(#"{"id":"p1","name":"Alpha","config":{"agent_id":"a1"}}"#))
    server.route(
      "/v1/projects/p1", method: "PATCH",
      .json(#"{"id":"p1","name":"Alpha","config":{"agent_id":"a1","icon":"🔥"}}"#))
    let store = try await connected(server)
    let list = store.sessionList
    await list.loadProjects()
    #expect(list.projectSortMode == .manual)

    #expect(await list.setProjectSortMode(.alphabetical, projects: list.projects))
    #expect(server.writes == ["PUT /v1/projects/order"])

    // An unchanged name is not renamed; only the icon is written.
    #expect(await list.editProject(list.projects[0], name: "Alpha", icon: "🔥"))
    #expect(server.writes == ["PUT /v1/projects/order", "PATCH /v1/projects/p1"])
  }

  @Test(.timeLimit(.minutes(1)))
  func failuresLandInEditError() async throws {
    let server = ListServer()
    server.route(
      "/v1/sessions/conv_b", method: "GET",
      .json(#"{"id":"conv_b","status":"idle","created_at":1,"permission_level":1}"#))
    let store = try await connected(server)
    let list = store.sessionList
    #expect(!(await list.delete("conv_b")))
    #expect(list.editError != nil)
    #expect(server.writes.isEmpty)

    server.route("/v1/sessions/conv_b/permissions/local", method: "DELETE", .json("{}"))
    #expect(await list.leave("conv_b"))
    #expect(list.editError == nil)
    #expect(server.writes == ["DELETE /v1/sessions/conv_b/permissions/local"])
  }
}
