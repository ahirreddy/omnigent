import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A session whose harness runs skills on the server rather than as text.
private let serverSkillFields = #"""
  "harness":"openai-agents","agent_id":"agent_1","host_id":"demo-host","host_online":true,
  "runner_online":true
  """#

/// Composer paths around skills, quotes, searches and held files.
@MainActor
@Suite("Composer details", .timeLimit(.minutes(1)))
struct ComposerGapTests {
  private func eventBodies(_ live: LiveComposer) throws -> [[String: Any]] {
    try live.server.requests(to: "/v1/sessions/conv_a/events", method: "POST").map {
      try live.server.body(of: $0)
    }
  }

  @Test("On a harness without its own skills, the skill runs on the server with its arguments")
  func skillRunsOnTheServer() async throws {
    let live = try await LiveComposer(fields: serverSkillFields)
    let composer = live.composer
    live.server.route(
      "/v1/skills", .json(#"{"skills":[{"name":"review","description":"Review"}]}"#))
    await composer.loadConfiguration()
    await composer.loadSkills()
    live.acceptMessages()

    composer.text = "/review the diff"
    await composer.send()
    #expect(composer.lastError == nil, "\(String(describing: composer.lastError))")
    #expect(composer.text.isEmpty)
    let body = try #require(try eventBodies(live).last)
    let data = try #require(body["data"] as? [String: Any])
    #expect(body["type"] as? String == "slash_command")
    #expect(data["kind"] as? String == "skill")
    #expect(data["name"] as? String == "review")
    #expect(data["arguments"] as? String == "the diff")
  }

  @Test("Editing the text before a quote changes only that quote; a stale index does nothing")
  func quoteLeads() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    composer.quote("first line")
    composer.editQuoteLead(at: 0, text: "about this:")
    #expect(composer.quotes[0].before == "about this:")
    composer.editQuoteLead(at: 0, text: "about this:")
    composer.editQuoteLead(at: 5, text: "stale")
    #expect(composer.quotes.map(\.before) == ["about this:"])
  }

  @Test("A newer @ query replaces the one still waiting, so only it searches")
  func supersededMentionSearch() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    var searched: [String] = []
    composer.searchMentions = { query in
      searched.append(query)
      return ["src/\(query).swift"]
    }
    composer.text = "see @old"
    composer.text = "see @new"
    try await eventually("the search") { composer.mentionCandidates == ["src/new.swift"] }
    #expect(searched == ["new"])
  }

  @Test("A queued file whose hold can't be dropped or restored keeps the reason")
  func heldFilesWithNoConnection() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    let item = try #require(composer.attachments.items.first)
    live.server.route(
      "/v1/sessions/conv_a/resources/files", method: "POST",
      .json(#"{"id":"file_1","session_id":"conv_a"}"#, status: 201))
    await composer.upload(item.id)
    composer.text = "with a file"
    composer.queueDraft()
    let queued = try #require(composer.queue.items.first)
    #expect(queued.extras.holdID != nil)

    live.store.disconnect()
    try await eventually("the disconnect") { live.store.phase == .disconnected }

    composer.lastError = nil
    #expect(composer.takeLastQueued() == nil)
    #expect(composer.lastError != nil)
    #expect(composer.queue.items.count == 1, "the message stays rather than losing its file")

    composer.lastError = nil
    composer.removeQueued(queued.id)
    #expect(composer.lastError != nil)
  }

  @Test("A release cancels the wait to recheck the host, so a held message isn't sent twice")
  func recheckCancelled() async throws {
    let live = try await LiveComposer(fields: claudeFields("default"))
    let composer = live.composer
    live.hostIsOffline()
    composer.text = "hello"
    await composer.send()
    #expect(composer.hostRecheck != nil, "the header says online, so the refusal is retried")

    live.acceptMessages()
    await composer.releaseHeldMessages()
    #expect(composer.hostRecheck == nil)
    await Task.yield()
    #expect(composer.queue.items.isEmpty)
    #expect(live.postedTexts.filter { $0 == "hello" }.count == 2, "the refusal, then the send")
  }

  @Test("Steering follows the session's harness")
  func steering() async throws {
    let live = try await LiveComposer(fields: claudeFields("default"))
    await live.composer.loadConfiguration()
    #expect(live.composer.supportsSteering == live.composer.rules.supportsSteering)
  }
}

/// The new-session form's sandbox path when the send, or the creation, doesn't work.
@MainActor
@Suite("Sandbox creation outcomes", .timeLimit(.minutes(1)))
struct SandboxCreationOutcomeTests {
  private let target = SandboxTarget(
    provider: "modal", profile: nil, workspaces: ["https://github.com/example/repo#main"])

  private func sandboxRoutes() throws -> RouteServer {
    let server = try creationRoutes()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"agent_install":true,"managed_sandboxes_enabled":true,"sandbox_providers":["modal"]}"#
      ))
    return server
  }

  private func acceptSandbox(_ server: RouteServer) throws {
    try acceptCreation(server)
  }

  private func createdPhase(_ creation: CreationStore) -> (String, CoreError?)? {
    if case .created(let id, let error) = creation.phase { return (id, error) }
    return nil
  }

  @Test("A blank first message creates the session and sends nothing")
  func blankMessage() async throws {
    let server = try sandboxRoutes()
    try acceptSandbox(server)
    let creation = try await loadedCreation(server)
    await creation.createInSandbox(
      newSessionSelection, target: target, title: "", firstMessage: "  \n")
    let (id, error) = try #require(createdPhase(creation))
    #expect(id == "conv_created")
    #expect(error == nil)
    #expect(server.requests(to: "/v1/sessions/conv_created/events").isEmpty)
  }

  @Test("A first message that fails leaves the session created, with the reason and the text")
  func firstMessageFails() async throws {
    let server = try sandboxRoutes()
    try acceptSandbox(server)
    server.fail("/v1/sessions/conv_created/events", method: "POST", status: 400)
    let creation = try await loadedCreation(server)
    await creation.createInSandbox(
      newSessionSelection, target: target, title: "", firstMessage: "go")
    let (id, error) = try #require(createdPhase(creation))
    #expect(id == "conv_created")
    #expect(error != nil)

    server.route("/v1/sessions/conv_created/events", method: "POST", .json(#"{"queued":true}"#))
    await creation.retryFirstMessage()
    #expect(createdPhase(creation)?.1 == nil, "the kept text goes on the retry")
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").count == 2)
  }

  @Test("A refused creation is a failure the form can retry")
  func refused() async throws {
    let server = try sandboxRoutes()
    server.fail("/v1/sessions", method: "POST", status: 400, detail: "no sandbox")
    let creation = try await loadedCreation(server)
    await creation.createInSandbox(
      newSessionSelection, target: target, title: "", firstMessage: "go")
    guard case .failed = creation.phase else {
      Issue.record("phase: \(creation.phase)")
      return
    }
    #expect(createdPhase(creation) == nil)
  }
}
