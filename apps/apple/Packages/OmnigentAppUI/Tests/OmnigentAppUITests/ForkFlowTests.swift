import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A loopback server that answers the fork routes; `launch` answers starting the fork.
nonisolated private func forkServer(fork: HttpResponse, launch: HttpResponse) -> FakeHttpTransport {
  FakeHttpTransport { request throws(TransportError) in
    switch URLComponents(string: request.url)?.path ?? "" {
    case "/.well-known/omnigent.json": return .json(ManifestFixtures.localNoAuth)
    case "/v1/info": return .json(#"{"single_user":true,"accounts_enabled":false}"#)
    case "/v1/me": return .json(#"{"user_id":"local"}"#)
    case "/v1/sessions": return .json(#"{"data":[],"has_more":false}"#)
    case "/v1/hosts":
      return .json(#"{"hosts":[{"host_id":"host_a","name":"Mac","status":"online"}]}"#)
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
private func connectedForkStore(_ http: FakeHttpTransport) async throws -> ForkStore {
  let core = try ClientCore(
    http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
    clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  let connection = ConnectionStore(core: core)
  await connection.connect(serverURL: "http://127.0.0.1:6767")
  #expect(connection.isSignedIn, "phase: \(connection.phase)")
  return try #require(connection.makeForkStore())
}

private func source() -> OmnigentCoreFFI.SessionSummary {
  OmnigentCoreFFI.SessionSummary(
    id: "conv_src", title: "Plan", preview: "", status: .idle, isReadOnly: false,
    updatedAt: 1, workspace: "/work/project", agentName: "codex-native-ui",
    isPinned: false, isArchived: false, permissionLevel: 4, failureMessage: nil,
    canRename: true, canPin: true, canArchive: true,
    configuration: SessionConfiguration(
      agentId: "ag_clone", harness: "codex-native", wrapper: nil, modelOverride: nil,
      baseModel: nil, effort: nil, modelReported: nil, effortReported: nil, models: [],
      hostId: "host_a", hostOnline: true, runnerOnline: true, runnerBound: true,
      hostResumable: nil, parentId: nil, routingMode: nil))
}

/// What the flow asked the app to show.
@MainActor
private final class Shown {
  var opened: [String] = []
  var reports: [String] = []
}

/// The fork sheet's flow over a real core and a loopback server: what the hover action's sheet
/// does after the user picks Fork.
@MainActor
@Suite("Fork flow")
struct ForkFlowTests {
  @Test("A fork from a message opens the new session and closes the sheet")
  func opensTheFork() async throws {
    let store = try await connectedForkStore(
      forkServer(fork: forked, launch: .json("{}", status: 404)))
    let flow = ForkFlow()
    await flow.begin(
      ForkContext(source: source(), upToResponseID: "resp_2", kind: .fromMessage(rowID: "item_a")),
      makeStore: { store })
    #expect(flow.viewState?.title == "Fork from this response")

    let shown = Shown()
    await flow.fork(
      agentID: "ag_clone", directory: "/work/project", start: false,
      open: { shown.opened.append($0) }, report: { shown.reports.append($0) })

    #expect(shown.opened == ["conv_fork"])
    #expect(shown.reports.isEmpty)
    #expect(flow.viewState == nil, "the sheet stays open after the fork exists")
  }

  @Test("A fork that cannot start still opens, and the failure is reported outside the sheet")
  func reportsAFailedStart() async throws {
    let store = try await connectedForkStore(
      forkServer(fork: forked, launch: .json(#"{"detail":"Host is busy"}"#, status: 409)))
    let flow = ForkFlow()
    await flow.begin(
      ForkContext(source: source(), upToResponseID: "resp_2", kind: .fromMessage(rowID: "item_a")),
      makeStore: { store })

    let shown = Shown()
    await flow.fork(
      agentID: "ag_clone", directory: "/work/project", start: true,
      open: { shown.opened.append($0) }, report: { shown.reports.append($0) })

    #expect(shown.opened == ["conv_fork"])
    #expect(shown.reports == ["The fork was created but did not start: Host is busy"])
  }

  @Test("A refused fork opens nothing and keeps the sheet with the server's reason")
  func keepsTheSheetOnRefusal() async throws {
    let store = try await connectedForkStore(
      forkServer(
        fork: .json(#"{"error":{"message":"No such response"}}"#, status: 400),
        launch: .json("{}", status: 404)))
    let flow = ForkFlow()
    await flow.begin(
      ForkContext(source: source(), upToResponseID: "resp_2", kind: .fromMessage(rowID: "item_a")),
      makeStore: { store })

    let shown = Shown()
    await flow.fork(
      agentID: "ag_clone", directory: "/work/project", start: false,
      open: { shown.opened.append($0) }, report: { shown.reports.append($0) })

    #expect(shown.opened.isEmpty)
    #expect(flow.viewState?.errorMessage == "No such response")
  }
}
