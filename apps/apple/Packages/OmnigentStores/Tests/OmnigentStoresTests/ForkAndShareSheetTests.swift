import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The fork sheet's reads: a failure stays with what it failed to load.
@MainActor
@Suite("The fork sheet", .timeLimit(.minutes(1)))
struct ForkSheetTests {
  private let optionsPath = "/v1/hosts/host_a/harnesses/codex-native/model-options"

  private func sheet(_ server: RouteServer) async throws -> ForkStore {
    let connection = try await connectedStore(server)
    return try #require(connection.makeForkStore())
  }

  @Test("A catalog that can't be read is kept and leaves a start unavailable")
  func catalogFailure() async throws {
    let server = RouteServer()
    server.fail("/v1/hosts")
    let fork = try await sheet(server)
    await fork.loadCatalog()
    guard case .failed = fork.catalog else {
      Issue.record("catalog: \(fork.catalog)")
      return
    }
    let source = SessionSummary(
      id: "conv_a", title: "a", preview: "", status: .idle, pendingRequests: 0, isReadOnly: false,
      updatedAt: 1, workspace: "", agentName: "", isPinned: false, isArchived: false,
      permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true, canArchive: true)
    #expect(fork.plan(for: source).hosts.isEmpty)
  }

  @Test("Picking a host reads its models; no host or agent clears them")
  func models() async throws {
    let fork = try await sheet(try creationRoutes())
    await fork.loadCatalog()
    let agent = try #require(fork.catalog.value?.agents.first { $0.harness == "codex-native" })

    await fork.loadModels(agentID: agent.id, hostID: "host_a")
    #expect(fork.models.value?.isEmpty == false)

    await fork.loadModels(agentID: agent.id, hostID: nil)
    #expect(fork.models == .idle)
    await fork.loadModels(agentID: "", hostID: "host_a")
    #expect(fork.models == .idle)
  }

  @Test("A models read that fails says so, and a newer choice beats an older one's answer")
  func modelFailureAndRace() async throws {
    let server = try creationRoutes()
    let fork = try await sheet(server)
    await fork.loadCatalog()
    let agent = try #require(fork.catalog.value?.agents.first { $0.harness == "codex-native" })
    let answer = server.respond(
      HttpRequest(method: "GET", url: "http://127.0.0.1:6767\(optionsPath)", headers: [], body: nil)
    )
    server.fail(optionsPath)
    await fork.loadModels(agentID: agent.id, hostID: "host_a")
    guard case .failed = fork.models else {
      Issue.record("models: \(fork.models)")
      return
    }

    let gate = server.hold(optionsPath)
    async let older: Void = fork.loadModels(agentID: agent.id, hostID: "host_a")
    try await eventually("the first read") { gate.arrivals > 0 }
    await fork.loadModels(agentID: agent.id, hostID: nil)
    server.route(optionsPath, answer)
    gate.release()
    await older
    #expect(fork.models == .idle, "the older answer is dropped")
  }

  @Test("The folder browser gets the listing or the reason")
  func directory() async throws {
    let server = try creationRoutes()
    let fork = try await sheet(server)
    guard case .success(let listing) = await fork.directory(hostID: "host_a", path: nil) else {
      Issue.record("expected a listing")
      return
    }
    #expect(listing.directories.map(\.name) == ["project"])

    server.fail("/v1/hosts/host_a/filesystem", status: 403, detail: "denied")
    guard case .failure(let error) = await fork.directory(hostID: "host_a", path: nil) else {
      Issue.record("expected a failure")
      return
    }
    #expect(error.message.contains("denied"))
  }

  @Test("Nothing forks while another is running, and reset only clears a finished one")
  func oneAtATime() async throws {
    let server = RouteServer()
    let path = "/v1/sessions/conv_a/fork"
    let gate = server.hold(path)
    server.route(
      path,
      .json(#"{"id":"conv_f","status":"idle","created_at":5,"permission_level":4}"#, status: 201))
    let fork = try await sheet(server)
    let request = ForkRequest(
      sourceId: "conv_a", upToResponseId: "r1", agentId: nil, title: nil, start: nil)
    async let first = fork.fork(request)
    try await eventually("the first fork") { gate.arrivals > 0 }
    #expect(await fork.fork(request) == nil, "a double click doesn't fork twice")
    fork.reset()
    #expect(fork.phase == .forking)
    gate.release()
    #expect(await first == "conv_f")
    #expect(server.requests(to: path).count == 1)
    fork.reset()
    #expect(fork.phase == .idle)
  }
}

/// The share sheet: every write reloads what the sheet shows, and a failure stays with the sheet.
@MainActor
@Suite("The share sheet", .timeLimit(.minutes(1)))
struct ShareSheetTests {
  private let path = "/v1/sessions/conv_a/permissions"

  private func sheet(_ server: RouteServer) async throws -> ShareStore {
    let connection = try await connectedStore(server)
    return try #require(connection.share(sessionID: "conv_a"))
  }

  private func grants(_ entries: String) -> HttpResponse {
    .json(#"{"permissions":[\#(entries)],"next_cursor":null}"#)
  }

  @Test("Grants that can't be read show the failure")
  func readFailure() async throws {
    let server = RouteServer()
    server.fail(path, status: 403)
    let share = try await sheet(server)
    await share.load()
    guard case .failed = share.grants else {
      Issue.record("grants: \(share.grants)")
      return
    }
    #expect(!share.isPublic)
  }

  @Test("Removing someone reloads the list")
  func revokes() async throws {
    let server = RouteServer()
    server.route(path, grants(#"{"user_id":"local","level":4}"#))
    server.route("\(path)/bob", method: "DELETE", .json("{}"))
    let share = try await sheet(server)
    await share.revoke("bob")
    #expect(share.error == nil)
    #expect(share.grants.value?.map(\.userId) == ["local"])
    #expect(server.requests(to: "\(path)/bob", method: "DELETE").count == 1)

    server.fail("\(path)/bob", method: "DELETE")
    await share.revoke("bob")
    #expect(share.error != nil, "the failure stays with the sheet")
    #expect(share.grants.value?.map(\.userId) == ["local"], "the list stays too")
  }

  @Test("The public link grants the public read level and takes it away")
  func publicLink() async throws {
    let server = RouteServer()
    server.route(path, grants(#"{"user_id":"local","level":4}"#))
    server.route(
      path, method: "PUT",
      .json(#"{"user_id":"__public__","level":1,"conversation_id":"conv_a"}"#))
    let share = try await sheet(server)
    await share.load()
    #expect(!share.isPublic)

    server.route(
      path, grants(#"{"user_id":"local","level":4},{"user_id":"__public__","level":1}"#))
    await share.setPublic(true)
    #expect(share.error == nil, "\(String(describing: share.error))")
    #expect(share.isPublic)
    let granted = try #require(server.requests(to: path, method: "PUT").last)
    let body = try server.body(of: granted)
    #expect(body["user_id"] as? String == "__public__")
    #expect(body["level"] as? Int == 1)

    server.route(path, grants(#"{"user_id":"local","level":4}"#))
    server.route("\(path)/__public__", method: "DELETE", .json("{}"))
    await share.setPublic(false)
    #expect(!share.isPublic)
    #expect(server.requests(to: "\(path)/__public__", method: "DELETE").count == 1)
  }
}
