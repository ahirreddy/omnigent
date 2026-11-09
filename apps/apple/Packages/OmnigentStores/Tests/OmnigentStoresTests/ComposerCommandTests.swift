import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// What the `/` commands do once the core recognizes them in the draft.
@MainActor
@Suite("Composer commands", .timeLimit(.minutes(1)))
struct ComposerCommandTests {
  private func eventBodies(_ live: LiveComposer) throws -> [[String: Any]] {
    try live.server.requests(to: "/v1/sessions/conv_a/events", method: "POST").map {
      try live.server.body(of: $0)
    }
  }

  @Test("/clear posts the control; a failure puts the command back to retry")
  func clears() async throws {
    let server = RouteServer()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"session_event_types":["message","clear"]}"#
      ))
    let live = try await LiveComposer(server: server, fields: claudeFields("default"))
    let composer = live.composer
    await composer.loadConfiguration()
    await composer.loadSkills()
    #expect(composer.slashOptions.serverClears)

    composer.text = "/clear"
    await composer.send()
    #expect(composer.text == "/clear")
    #expect(composer.lastError != nil)

    live.acceptMessages()
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(try eventBodies(live).last?["type"] as? String == "clear")
  }

  @Test("/compact goes through the send ledger and clears the draft")
  func compacts() async throws {
    let live = try await LiveComposer(fields: claudeFields("default"))
    live.acceptMessages()
    let composer = live.composer
    await composer.loadConfiguration()
    composer.text = "/compact"
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(composer.lastError == nil)
    #expect(try eventBodies(live).count == 1)
  }

  @Test("On a native harness a skill goes as text, and read failures explain the missing ones")
  func skills() async throws {
    let live = try await LiveComposer(fields: claudeFields("default"))
    live.acceptMessages()
    let composer = live.composer
    await composer.loadConfiguration()

    await composer.loadSkills()
    #expect(composer.skillsProblem?.hasPrefix("Skills are unavailable") == true)
    #expect(composer.skills.isEmpty)

    live.server.route(
      "/v1/skills",
      .json(#"{"skills":[{"name":"review","description":"Review"}],"warnings":["bad.md"]}"#))
    await composer.loadSkills()
    #expect(composer.skills.map(\.name) == ["review"])
    #expect(composer.skillsProblem == "Some skills could not be read: bad.md")
    #expect(composer.slashCommands.contains { $0.name.contains("review") })

    live.server.fail("/v1/info")
    live.server.route("/v1/skills", .json(#"{"skills":[{"name":"review","description":"R"}]}"#))
    await composer.loadSkills()
    #expect(composer.skillsProblem?.hasPrefix("Some commands are unavailable") == true)

    composer.text = "/review the diff"
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(composer.lastError == nil)
    #expect(try eventBodies(live).count == 1)
  }

  @Test("/permissions opens Codex's picker; Claude's own command goes to Claude")
  func permissions() async throws {
    let live = try await LiveComposer(fields: codexFields)
    let composer = live.composer
    await composer.loadConfiguration()
    composer.text = "/permissions"
    await composer.send()
    #expect(composer.approvalPickerRequests == 1)
    #expect(composer.text.isEmpty)
    #expect(composer.commandNotice == nil)
    composer.text = "/permissions now"
    await composer.send()
    #expect(composer.commandNotice == "/permissions does not accept arguments")

    let claude = try await LiveComposer(fields: claudeFields("default"))
    claude.acceptMessages()
    await claude.composer.loadConfiguration()
    claude.composer.text = "/permissions"
    await claude.composer.send()
    #expect(claude.composer.approvalPickerRequests == 0)
    #expect(claude.postedTexts == ["/permissions"])
  }

  @Test("A plain message that starts with a slash still sends before settings load")
  func slashBeforeConfiguration() async throws {
    let live = try await LiveComposer()
    live.acceptMessages()
    live.composer.text = "/usr/bin is the path"
    await live.composer.send()
    #expect(live.postedTexts == ["/usr/bin is the path"])
  }

  @Test("A failed core draft write shows, and the stream's text wins once the core has any")
  func draftSync() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    composer.text = "typed"
    composer.quotes = [ReplyQuote(before: "", text: "said")]
    composer.streamReady()
    #expect(composer.lastError == nil)
    #expect(composer.text == "typed")
    #expect(composer.quotes.count == 1, "the core's text is still this draft's own message")

    composer.setText(fromCore: "from the core")
    #expect(composer.text == "from the core")
    #expect(composer.quotes.isEmpty)
  }

  @Test("A /compact Codex controls itself and one sent as text both clear the draft")
  func compactsByControl() async throws {
    let live = try await LiveComposer(fields: codexFields)
    live.acceptMessages()
    let composer = live.composer
    await composer.loadConfiguration()
    composer.text = "/compact"
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(composer.lastError == nil)
  }

  @Test("Mentions alone can be sent and go ahead of the message")
  func mentionsOnly() async throws {
    let live = try await LiveComposer(fields: claudeFields("default"))
    live.acceptMessages()
    let composer = live.composer
    await composer.loadConfiguration()
    composer.addMention("src/a.swift")
    #expect(composer.canSend)
    await composer.send()
    #expect(composer.mentions.isEmpty, "sent")
    #expect(composer.lastError == nil)
    #expect(live.postedTexts.count == 1)
    #expect(live.postedTexts.first?.contains("src/a.swift") == true)
  }

  @Test("A refused message keeps its mentions for the retry")
  func refusedMentions() async throws {
    let live = try await LiveComposer(fields: claudeFields("default"))
    live.server.fail("/v1/sessions/conv_a/events", method: "POST", status: 400)
    let composer = live.composer
    await composer.loadConfiguration()
    composer.addMention("src/a.swift")
    composer.text = "look"
    await composer.send()
    #expect(composer.mentions == ["src/a.swift"])
    #expect(composer.text == "look")
  }
}
