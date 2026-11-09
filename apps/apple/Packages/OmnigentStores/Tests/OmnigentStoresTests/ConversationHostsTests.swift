import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
@Suite("Moving a session between hosts", .timeLimit(.minutes(1)))
struct ConversationHostsTests {
  private let sessionPath = "/v1/sessions/conv_a"
  private let runnersPath = "/v1/hosts/host_b/runners"
  private let owned =
    #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"host_id":"host_a"}"#
  private let hostsJSON =
    #"{"hosts":[{"host_id":"host_a","name":"Old","status":"offline"},{"host_id":"host_b","name":"New","status":"online"}]}"#

  private func switching(_ server: RouteServer) {
    server.route(sessionPath, method: "GET", .json(owned))
    server.route(sessionPath, method: "PATCH", .json(owned))
    server.route("/v1/hosts", .json(hostsJSON))
    server.route(runnersPath, method: "POST", .json(#"{"runner_id":"runner_new"}"#, status: 201))
  }

  private func conversation(_ server: RouteServer) async throws -> ConversationStore {
    let store = try await connectedStore(server)
    return try #require(store.conversation("conv_a"))
  }

  @Test("The host list and folder browser read through; a failed read throws")
  func reads() async throws {
    let server = RouteServer()
    server.route("/v1/hosts", .json(hostsJSON))
    server.route(
      "/v1/hosts/host_a/filesystem/work",
      .json(
        #"{"data":[{"name":"project","path":"/work/project","type":"directory"}],"has_more":false}"#
      ))
    let conversation = try await conversation(server)
    #expect(try await conversation.hosts().map(\.hostId) == ["host_a", "host_b"])
    let listing = try await conversation.hostDirectory(hostID: "host_a", path: "/work")
    #expect(listing.directories.map(\.path) == ["/work/project"])

    server.fail("/v1/hosts")
    server.fail("/v1/hosts/host_a/filesystem/work")
    await #expect(throws: CoreError.self) { try await conversation.hosts() }
    await #expect(throws: CoreError.self) {
      try await conversation.hostDirectory(hostID: "host_a", path: "/work")
    }
  }

  @Test("A switch releases the old host, then launches on the new one")
  func switchesHost() async throws {
    let server = RouteServer()
    switching(server)
    let conversation = try await conversation(server)
    let launch = try await conversation.switchHost(to: "host_b", workspace: "/work")
    #expect(launch == .launched(runnerId: "runner_new"))
    #expect(server.requests(to: sessionPath, method: "PATCH").count == 1)
    #expect(server.requests(to: runnersPath, method: "POST").count == 1)
  }

  @Test("A launch that fails after the release says the session runs nowhere")
  func launchFailsAfterRelease() async throws {
    let server = RouteServer()
    switching(server)
    server.route(
      runnersPath, method: "POST",
      .json(#"{"error":{"message":"workspace outside the sandbox"}}"#, status: 400))
    let conversation = try await conversation(server)
    guard case .failed = try await conversation.switchHost(to: "host_b", workspace: "/work") else {
      Issue.record("expected a failed launch")
      return
    }
  }

  @Test("A refused release throws, and nothing launches")
  func refusedRelease() async throws {
    let server = RouteServer()
    switching(server)
    server.fail(sessionPath, method: "PATCH")
    let conversation = try await conversation(server)
    await #expect(throws: CoreError.self) {
      try await conversation.switchHost(to: "host_b", workspace: "/work")
    }
    #expect(server.requests(to: runnersPath, method: "POST").isEmpty)
  }

  @Test("Resuming launches on the chosen host; an offline host is refused before any write")
  func resumes() async throws {
    let server = RouteServer()
    switching(server)
    let conversation = try await conversation(server)
    try await conversation.resume(onHost: "host_b", workspace: "/work", git: nil)
    #expect(server.requests(to: runnersPath, method: "POST").count == 1)

    await #expect(throws: CoreError.self) {
      try await conversation.resume(onHost: "host_a", workspace: "/work", git: nil)
    }
    #expect(server.requests(to: runnersPath, method: "POST").count == 1)
  }

  @Test("The terminal's sign-in is read when asked; a link that isn't web is dropped")
  func signInLink() async throws {
    let server = RouteServer()
    let path = "\(sessionPath)/sign-in-link"
    server.route(
      path, .json(#"{"pending":true,"url":"https://example.cloud/oidc?x=1","code":"ABCD-1234"}"#))
    let conversation = try await conversation(server)
    let link = try await conversation.signInLink()
    #expect(link.pending)
    #expect(link.code == "ABCD-1234")

    server.route(path, .json(#"{"pending":true,"url":"file:///etc/passwd","code":null}"#))
    #expect(try await conversation.signInLink().url == nil)

    server.fail(path, status: 503)
    await #expect(throws: CoreError.self) { try await conversation.signInLink() }
  }
}
