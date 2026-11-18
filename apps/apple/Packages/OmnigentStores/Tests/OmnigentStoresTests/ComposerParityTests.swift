import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The web composer's `/clear` on Claude SDK, `/goal`, `/rewind`, and Edit and resend.
@MainActor
@Suite("Composer parity", .timeLimit(.minutes(1)))
struct ComposerParityTests {
  /// A claude-sdk session.
  private let sdkFields = #"""
    "harness":"claude-sdk","agent_id":"claude","host_id":"demo-host","host_online":true,
    "runner_online":true
    """#

  /// `/v1/info` as main's server sends its command fields.
  private func mainInfo(_ server: RouteServer) {
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"session_event_types":["message","clear"],"#
          + #""session_claude_sdk_clear":true,"session_rewind":true}"#))
  }

  private func composer(fields: String) async throws -> LiveComposer {
    let server = RouteServer()
    mainInfo(server)
    let live = try await LiveComposer(server: server, fields: fields)
    await live.composer.loadConfiguration()
    await live.composer.loadSkills()
    return live
  }

  @Test("A claude-sdk /clear opens the new session the server names")
  func sdkClearFollowsTheNewSession() async throws {
    let live = try await composer(fields: sdkFields)
    let composer = live.composer
    #expect(composer.slashOptions.claudeSdkClears && composer.slashOptions.rewinds)
    #expect(composer.slashCommands.map(\.name).starts(with: ["compact", "clear", "rewind"]))
    live.server.route(
      "/v1/sessions/conv_a/events", method: "POST",
      .json(#"{"queued":false,"session_id":"conv_b"}"#))
    composer.text = "/clear"
    #expect(await composer.send() == .openSession("conv_b"))
    #expect(composer.text.isEmpty)
  }

  @Test("/goal opens the sheet, and /goal with an objective sends it as a message")
  func goal() async throws {
    let live = try await composer(fields: sdkFields)
    live.acceptMessages()
    let composer = live.composer
    composer.text = "/goal"
    #expect(await composer.send() == .handled, "no Goal control: it is not a command")
    #expect(live.postedTexts == ["/goal"])

    composer.offersGoal = true
    #expect(composer.slashCommands.contains { $0.name == "goal" })
    composer.text = "/goal"
    #expect(await composer.send() == .goal)
    #expect(composer.text.isEmpty)
    composer.text = "/Goal  ship it"
    #expect(await composer.send() == .handled)
    #expect(live.postedTexts.last == "/goal ship it")
  }

  @Test("/rewind lists the prompts, then continues from one in a new session")
  func rewind() async throws {
    let live = try await composer(fields: claudeFields("default"))
    let composer = live.composer
    composer.text = "/rewind"
    #expect(await composer.send() == .rewind)
    #expect(composer.text.isEmpty)
    let picker = try #require(composer.rewindPicker)

    live.server.route(
      "/v1/sessions/conv_a/items",
      .json(
        #"{"data":[{"id":"msg_2","type":"message","role":"user","#
          + #""content":[{"type":"input_text","text":"Second"}]},"#
          + #"{"id":"msg_1","type":"message","role":"user","#
          + #""content":[{"type":"input_text","text":"First"}]}],"#
          + #""last_id":"msg_1","has_more":false}"#))
    await picker.load()
    #expect(picker.phase == .loaded)
    #expect(picker.prompts.map(\.text) == ["Second", "First"])
    #expect(picker.olderCursor == nil)
    let read = try #require(live.server.requests(to: "/v1/sessions/conv_a/items").last)
    #expect(read.url.contains("type=message") && read.url.contains("order=desc"))

    live.server.route(
      "/v1/sessions/conv_a/rewind", method: "POST",
      .json(#"{"session_id":"conv_r","prompt":"Second","attachments_incomplete":true}"#))
    let outcome = await composer.rewind(to: picker.prompts[0])
    #expect(composer.rewindPicker == nil)
    #expect(outcome?.sessionID == "conv_r")
    #expect(outcome?.warning?.hasPrefix("Some attachments couldn't be restored") == true)
    #expect(try composer.core.composerText(sessionId: "conv_r") == "Second")
    let posted = try live.server.requests(to: "/v1/sessions/conv_a/rewind", method: "POST").map {
      try live.server.body(of: $0)["item_id"] as? String
    }
    #expect(posted == ["msg_2"])
  }

  @Test("A refused rewind says why under the composer and opens nothing")
  func rewindRefused() async throws {
    let live = try await composer(fields: claudeFields("default"))
    let composer = live.composer
    live.server.fail(
      "/v1/sessions/conv_a/rewind", method: "POST", status: 400,
      detail: "Stop the current turn before running /rewind.")
    let prompt = RewindPrompt(itemId: "msg_1", text: "First", createdAt: nil)
    #expect(await composer.rewind(to: prompt) == nil)
    #expect(composer.commandNotice?.contains("Stop the current turn") == true)
  }

  @Test("An older server leaves /rewind and the SDK's /clear as text")
  func olderServer() async throws {
    let live = try await LiveComposer(fields: sdkFields)
    live.acceptMessages()
    let composer = live.composer
    await composer.loadConfiguration()
    await composer.loadSkills()
    #expect(!composer.slashCommands.contains { $0.name == "rewind" || $0.name == "clear" })
    composer.text = "/rewind"
    #expect(await composer.send() == .handled)
    #expect(composer.rewindPicker == nil)
    #expect(live.postedTexts == ["/rewind"])
  }

  @Test("Edit and resend loads the message and its @ paths, asking before replacing a draft")
  func editSentMessage() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    composer.editSentMessage("[Attached: src/a.rs]\n\nFix the parser")
    #expect(composer.text == "Fix the parser")
    #expect(composer.mentions == ["src/a.rs"])
    #expect(composer.editLoads == 1)
    #expect(composer.pendingEdit == nil)

    composer.text = "my draft"
    composer.addAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("hi".utf8))
    composer.editSentMessage("Second try")
    #expect(composer.pendingEdit == "Second try")
    #expect(composer.text == "my draft", "the draft stays until the user agrees")
    composer.keepDraftOverEdit()
    #expect(composer.pendingEdit == nil)
    #expect(composer.text == "my draft")

    composer.editSentMessage("Second try")
    composer.replaceDraftWithEdit()
    #expect(composer.text == "Second try")
    #expect(composer.mentions.isEmpty)
    #expect(composer.attachments.items.isEmpty, "the draft's files go with it")
    #expect(composer.editLoads == 2)
    #expect(try composer.core.composerText(sessionId: "conv_a") == "Second try")

    composer.editSentMessage("  ")
    #expect(composer.pendingEdit == nil, "a blank message is nothing to edit")
  }
}
