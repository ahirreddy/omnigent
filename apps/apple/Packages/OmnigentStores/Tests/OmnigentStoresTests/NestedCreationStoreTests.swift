import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The creation routes with nested agents on under `policy`, a second machine, the source's own
/// sandbox host, and the source session itself.
private func nestedRoutes(policy: String = "any_host") throws -> RouteServer {
  let server = try creationRoutes()
  server.route(
    "/v1/info",
    .json(
      #"{"single_user":true,"accounts_enabled":false,"sibling_sessions":true,"sibling_session_destinations":"\#(policy)","managed_sandboxes_enabled":true,"sandbox_provider":"modal"}"#
    ))
  let host = { (id: String, sandbox: String) in
    #"{"host_id":"\#(id)","name":"\#(id)","status":"online"\#(sandbox),"configured_harnesses":{"codex-native":true}}"#
  }
  server.route(
    "/v1/hosts",
    .json(
      #"{"hosts":[\#(host("host_a", "")),\#(host("host_b", "")),\#(host("sbx", #","sandbox_provider":"modal""#))]}"#
    ))
  server.route(
    "/v1/sessions/conv_source",
    .json(
      #"{"id":"conv_source","status":"idle","created_at":1,"title":"Coordinator","host_id":"host_a","workspace":"/work/project","permission_level":4}"#
    ))
  try acceptCreation(server)
  server.route(
    "/v1/sessions/conv_created/events", method: "POST", .json(#"{"queued":true}"#))
  return server
}

private let source = NestedSource(
  sessionID: "conv_source", hostID: "host_a", token: "0123456789abcdef0123456789abcdef")
private let token = "0123456789abcdef0123456789abcdef"

/// Add nested agent in the store: the source read fresh, and the create beside it.
@MainActor
@Suite("Adding a nested agent", .timeLimit(.minutes(1)))
struct NestedCreationStoreTests {
  private func posted(_ server: RouteServer) throws -> [String: Any] {
    let request = try #require(server.requests(to: "/v1/sessions", method: "POST").last)
    return try server.body(of: request)
  }

  @Test("The source is read fresh; one that is gone is an error")
  func readsTheSource() async throws {
    let server = try nestedRoutes()
    let creation = try await loadedCreation(server)
    let read = await creation.nestedSource("conv_source")
    #expect((try? read.get())?.title == "Coordinator")
    #expect((try? read.get())?.configuration?.hostId == "host_a")
    guard case .failure = await creation.nestedSource("conv_gone") else {
      Issue.record("a missing source read as present")
      return
    }
  }

  @Test("Start sends the source and the token, never a project, then the first message")
  func createsBesideTheSource() async throws {
    let server = try nestedRoutes()
    let creation = try await loadedCreation(server)
    var selection = newSessionSelection
    selection.projectId = "proj_other"
    await creation.createNested(
      selection, beside: source, title: "", firstMessage: "Write the tests")
    #expect(creation.phase == .created(sessionID: "conv_created", firstMessageError: nil))
    let body = try posted(server)
    #expect(body["sibling_source_id"] as? String == "conv_source")
    #expect((body["labels"] as? [String: String])?["omnigent.client_create_token"] == token)
    #expect(body["project_id"] == nil)
    #expect(body["initial_items"] == nil)
    #expect(body["parent_session_id"] == nil)
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").count == 1)
  }

  @Test("With no first message nothing is sent; staged files go with one")
  func emptyAndAttached() async throws {
    let server = try nestedRoutes()
    server.route(
      "/v1/sessions/conv_created/resources/files", method: "POST",
      .json(#"{"id":"file_1","session_id":"conv_created"}"#, status: 201))
    let creation = try await loadedCreation(server)
    await creation.createNested(
      newSessionSelection, beside: source, title: "", firstMessage: " ")
    #expect(creation.phase == .created(sessionID: "conv_created", firstMessageError: nil))
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").isEmpty)
    creation.reset()

    creation.stageAttachment(
      PendingAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("x".utf8)))
    await creation.createNested(
      newSessionSelection, beside: source, title: "", firstMessage: "Look")
    #expect(creation.phase == .created(sessionID: "conv_created", firstMessageError: nil))
    #expect(creation.attachments.isEmpty)
    #expect(server.requests(to: "/v1/sessions/conv_created/resources/files").count == 1)
    #expect(try posted(server)["sibling_source_id"] as? String == "conv_source")
  }

  @Test("The server's refusal reads clearly and nothing is created")
  func refused() async throws {
    let server = try nestedRoutes()
    server.route(
      "/v1/sessions", method: "POST",
      .json(
        #"{"error":{"code":"conflict","message":"Sibling source is no longer available"}}"#,
        status: 409))
    let creation = try await loadedCreation(server)
    await creation.createNested(
      newSessionSelection, beside: source, title: "", firstMessage: "hi")
    guard case .failed(let error) = creation.phase else {
      Issue.record("phase: \(creation.phase)")
      return
    }
    #expect(error.message == "The source session is no longer available. Nothing was created.")
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").isEmpty)
    #expect(creation.canCreate)
  }

  @Test("A new sandbox goes out managed beside the source, where the policy allows it")
  func sandbox() async throws {
    let server = try nestedRoutes(policy: "current_host_or_new_sandbox")
    let creation = try await loadedCreation(server)
    await creation.createNestedInSandbox(
      newSessionSelection, target: SandboxTarget(provider: "modal", profile: nil, workspaces: []),
      beside: source, title: "", firstMessage: "")
    #expect(creation.phase == .created(sessionID: "conv_created", firstMessageError: nil))
    let body = try posted(server)
    #expect(body["host_type"] as? String == "managed")
    #expect(body["sibling_source_id"] as? String == "conv_source")
  }

  @Test("Validation reuses only the source's sandbox and follows the policy")
  func validation() async throws {
    let anyHost = try await loadedCreation(try nestedRoutes())
    #expect(anyHost.nestedUnavailableReason(newSessionSelection, sourceHostID: "host_a") == nil)
    var onSandbox = newSessionSelection
    onSandbox.hostId = "sbx"
    #expect(anyHost.nestedUnavailableReason(onSandbox, sourceHostID: "sbx") == nil)
    #expect(anyHost.nestedUnavailableReason(onSandbox, sourceHostID: "host_a") != nil)

    let currentHost = try await loadedCreation(try nestedRoutes(policy: "current_host"))
    var elsewhere = newSessionSelection
    elsewhere.hostId = "host_b"
    let refusal = currentHost.nestedUnavailableReason(elsewhere, sourceHostID: "host_a")
    #expect(refusal?.contains("current host") == true)

    let server = try nestedRoutes()
    let unloaded = try #require(try await connectedStore(server).creation())
    #expect(
      unloaded.nestedUnavailableReason(newSessionSelection, sourceHostID: nil)
        == "The host and agent list has not loaded.")
  }

  @Test("Each create gets a fresh token of 32 lowercase hex digits")
  func tokens() {
    let first = CreationStore.newCreateToken()
    #expect(first.count == 32)
    #expect(first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(first != CreationStore.newCreateToken())
  }

  @Test("A provisional row opens, takes a new token, stands for its session, then retires")
  func provisionalRows() async throws {
    let creation = try await loadedCreation(try nestedRoutes())
    let source = try await creation.nestedSource("conv_source").get()
    creation.openNestedDraft(key: "draft", source: source, token: "first")
    creation.openNestedDraft(key: "draft", source: source, token: "second")
    #expect(creation.nestedDrafts.map(\.token) == ["second"])
    #expect(creation.nestedDrafts.first?.id == "draft")
    var pushed = source
    pushed.id = "conv_created"
    #expect(creation.nestedDrafts.first?.isReplaced(by: pushed) == false)
    pushed.clientCreateToken = "second"
    #expect(creation.nestedDrafts.first?.isReplaced(by: pushed) == true, "by its token")

    creation.nestedDraftCreated(key: "elsewhere", sessionID: "conv_other")
    creation.nestedDraftCreated(key: "draft", sessionID: "conv_created")
    #expect(creation.nestedDrafts.first?.id == "conv_created")
    creation.closeNestedDraft(key: "draft")
    var created = pushed
    created.clientCreateToken = nil
    creation.retireNestedDrafts { $0 == "conv_created" ? created : nil }
    #expect(creation.nestedDrafts.count == 1, "kept until the row has its family")
    created.family = SessionFamily(
      id: "conv_source", representativeId: "conv_source", representativeTitle: nil,
      pinned: false, pinnedAt: nil)
    creation.retireNestedDrafts { $0 == "conv_created" ? created : nil }
    #expect(creation.nestedDrafts.isEmpty)

    creation.openNestedDraft(key: "next", source: source, token: "third")
    creation.retireNestedDrafts { _ in nil }
    #expect(creation.nestedDrafts.count == 1)
    var archived = source
    archived.isArchived = true
    creation.retireNestedDrafts { $0 == "conv_source" ? archived : nil }
    #expect(creation.nestedDrafts.isEmpty, "its source was archived before a create")
    creation.openNestedDraft(key: "last", source: source, token: "fourth")
    creation.closeNestedDraft(key: "last")
    #expect(creation.nestedDrafts.isEmpty, "a row with no session leaves with its composer")
  }
}
