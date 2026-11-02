import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// A loopback server that answers the fork and launch routes with the given replies.
nonisolated private final class ForkServer: Sendable {
  let fork: HttpResponse
  let launch: HttpResponse
  let hostStatus: String
  let bodies = Mutex<[String: String]>([:])

  init(fork: HttpResponse, launch: HttpResponse = .json("{}", status: 404), hostStatus: String) {
    self.fork = fork
    self.launch = launch
    self.hostStatus = hostStatus
  }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    if let body = request.body, let text = String(bytes: body, encoding: .utf8) {
      bodies.withLock { $0[path] = text }
    }
    switch path {
    case "/.well-known/omnigent.json": return .json(ManifestFixtures.localNoAuth)
    case "/v1/info": return .json(#"{"single_user":true,"accounts_enabled":false}"#)
    case "/v1/me": return .json(#"{"user_id":"local"}"#)
    case "/v1/sessions": return .json(#"{"data":[],"has_more":false}"#)
    case "/v1/hosts":
      return .json(#"{"hosts":[{"host_id":"host_a","name":"Mac","status":"\#(hostStatus)"}]}"#)
    case "/v1/agents": return .json(#"{"data":[],"has_more":false}"#)
    case "/v1/sessions/conv_src/fork": return fork
    case "/v1/hosts/host_a/runners": return launch
    default: return .json(#"{"detail":"not found"}"#, status: 404)
    }
  }
}

private let forked = HttpResponse.json(
  #"{"id":"conv_fork","status":"idle","created_at":5,"permission_level":4}"#, status: 201)

@MainActor
private func connectedForkStore(_ server: ForkServer) async throws -> ForkStore {
  let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
  let core = try ClientCore(
    http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
    clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  let connection = ConnectionStore(core: core)
  await connection.connect(serverURL: "http://127.0.0.1:6767")
  #expect(connection.isSignedIn, "phase: \(connection.phase)")
  return try #require(connection.makeForkStore())
}

private func request(start: ForkStart? = nil) -> ForkRequest {
  ForkRequest(
    sourceId: "conv_src", upToResponseId: "resp_2", agentId: nil, title: nil, start: start)
}

@MainActor
struct ForkStoreTests {
  @Test func forkReturnsTheNewSessionAndSendsTheForkPoint() async throws {
    let server = ForkServer(fork: forked, hostStatus: "online")
    let store = try await connectedForkStore(server)

    let id = await store.fork(request())

    #expect(id == "conv_fork")
    #expect(store.phase == .forked(sessionID: "conv_fork", launchError: nil))
    let body = server.bodies.withLock { $0["/v1/sessions/conv_src/fork"] }
    #expect(body?.contains(#""up_to_response_id":"resp_2""#) == true, "\(body ?? "")")
  }

  @Test func aRejectionIsShownAndNothingIsReturned() async throws {
    let server = ForkServer(
      fork: .json(#"{"error":{"message":"No such response"}}"#, status: 400),
      hostStatus: "online")
    let store = try await connectedForkStore(server)

    let id = await store.fork(request())

    #expect(id == nil)
    guard case .failed = store.phase else {
      Issue.record("phase: \(store.phase)")
      return
    }
    #expect(store.errorMessage == "No such response")
    #expect(store.canFork)
  }

  @Test func anUnclearOutcomeBlocksForkingUntilAcknowledged() async throws {
    let server = ForkServer(fork: .json("{}", status: 503), hostStatus: "online")
    let store = try await connectedForkStore(server)

    #expect(await store.fork(request()) == nil)
    guard case .uncertain = store.phase else {
      Issue.record("phase: \(store.phase)")
      return
    }
    #expect(!store.canFork)
    #expect(await store.fork(request()) == nil)
    store.reset()
    #expect(!store.canFork)
    store.acknowledgeUncertain()
    #expect(store.canFork)
  }

  @Test func aFailedStartStillOpensTheForkAndReportsWhy() async throws {
    let server = ForkServer(
      fork: forked, launch: .json(#"{"detail":"Host is busy"}"#, status: 409),
      hostStatus: "online")
    let store = try await connectedForkStore(server)

    let id = await store.fork(
      request(start: ForkStart(hostId: "host_a", workspace: "/work/project")))

    #expect(id == "conv_fork")
    guard case .forked("conv_fork", let launchError?) = store.phase else {
      Issue.record("phase: \(store.phase)")
      return
    }
    #expect(launchError.message == "Host is busy")
  }

  @Test func loadsTheCatalogForThePlan() async throws {
    let server = ForkServer(fork: forked, hostStatus: "offline")
    let store = try await connectedForkStore(server)
    await store.loadCatalog()
    #expect(store.catalog.value?.hosts.map(\.hostId) == ["host_a"])
  }
}
