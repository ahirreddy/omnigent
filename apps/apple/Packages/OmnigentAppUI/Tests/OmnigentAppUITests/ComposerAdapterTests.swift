import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Composer adapter")
struct ComposerAdapterTests {
  private func configuration(wrapper: String, mode: String?, harness: String)
    -> OmnigentCoreFFI.SessionConfiguration
  {
    OmnigentCoreFFI.SessionConfiguration(
      agentId: "agent", harness: harness, wrapper: wrapper, modelOverride: nil, baseModel: nil,
      effort: nil, modelReported: true, effortReported: true, models: [], hostId: "host",
      hostOnline: true, runnerOnline: true, runnerBound: true, hostResumable: nil, parentId: nil,
      routingMode: nil, approvalMode: mode)
  }

  @Test("Each harness's own modes map to clear names, shields and risk")
  func approvalModes() throws {
    let codex = try #require(
      approvalModeMenu(
        configuration: configuration(
          wrapper: "codex-native-ui", mode: "approve-for-me", harness: "codex-native")))
    let modes = ComposerAdapter.approvalModes(codex)
    #expect(modes.title == "Codex approvals")
    #expect(modes.options.map(\.id) == ["ask-for-approval", "approve-for-me", "full-access"])
    #expect(modes.options.map(\.label) == ["Auto-edit", "Auto-approve", "Full access"])
    #expect(modes.selected?.harnessLabel == "Approve for me")
    #expect(modes.options.last?.risk == .fullAccess)
    #expect(modes.next?.id == "full-access")

    let claude = try #require(
      approvalModeMenu(
        configuration: configuration(
          wrapper: "claude-code-native-ui", mode: "bypassPermissions", harness: "claude-native")))
    let claudeModes = ComposerAdapter.approvalModes(claude)
    #expect(claudeModes.selected?.label == "Full access")
    #expect(claudeModes.selected?.isSwitchable == false)
    #expect(claudeModes.next == nil)

    #expect(
      approvalModeMenu(
        configuration: configuration(wrapper: "pi-native-ui", mode: nil, harness: "pi-native"))
        == nil)
  }

  @Test("The / menu keeps each command's prefix; Codex skills read $")
  func slashMenu() {
    let skill = Skill(name: "review", description: "Review the diff", displayName: nil)
    let commands = slashCommands(
      configuration: configuration(wrapper: "codex-native-ui", mode: nil, harness: "codex-native"),
      skills: [skill]
    )
    .map(ComposerAdapter.slashCommand)
    #expect(commands.map(\.id) == ["/compact", "/effort", "/model", "/new", "/help", "$review"])
    #expect(commands.last?.isSkill == true)
  }

  @Test("Error rows carry the core's Retry choice into the transcript")
  func errorRecovery() {
    func row(code: String) -> OmnigentUIComponents.Row {
      let activity = OmnigentCoreFFI.Activity(
        kind: .error, title: "Response error", summary: "", status: "failed",
        details: [
          OmnigentCoreFFI.DetailSection(id: "code", title: "Code", text: code, isCode: true)
        ],
        isFailure: true,
        recovery: code == "rate_limit_exceeded" ? .continue : nil)
      return OmnigentUIComponents.Row(
        OmnigentCoreFFI.Row(
          id: "e", role: .tool, text: "", isStreaming: false, activity: activity, attachments: [],
          callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil,
          createdAt: 1_700_000_000, isEphemeral: false, isActivityOnly: false))
    }
    let failed = row(code: "rate_limit_exceeded")
    #expect(failed.activity?.recovery == .continue)
    #expect(failed.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(row(code: "budget_exhausted").activity?.recovery == nil)
  }

  @Test("Steering follows the harness")
  func steering() {
    #expect(
      configurationSupportsSteering(
        configuration: configuration(wrapper: "codex-native-ui", mode: nil, harness: "codex-native")
      ))
    #expect(
      !configurationSupportsSteering(
        configuration: configuration(wrapper: "", mode: nil, harness: "claude-sdk")))
  }

  @Test("Queued items keep their id, text and failure")
  func queued() throws {
    var queue = MessageQueue()
    let item = try queue.enqueue("later")
    _ = try queue.begin(item.id)
    queue.finish(item.id, failure: "Refused")
    let message = ComposerAdapter.queued(try #require(queue.items.first))
    #expect(message.id == String(item.id))
    #expect(message.text == "later")
    #expect(message.state == .failed(message: "Refused"))
  }

  @Test("A read-only session's composer is read-only; a loading one is only unavailable")
  func readOnly() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let notes = try #require(store.conversation("demo-notes"))
    let question = try #require(store.conversation("demo-question"))
    #expect(!ComposerAdapter.isReadOnly(question))
    let deadline = ContinuousClock.now + .seconds(10)
    while notes.header == nil || question.header == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let readOnly = ComposerAdapter.state(notes, isStopping: false, dismissedError: nil)
    #expect(readOnly.isReadOnly)
    #expect(readOnly.availability.reason != nil)
    #expect(!ComposerAdapter.state(question, isStopping: false, dismissedError: nil).isReadOnly)
  }
}

@Suite("Message links")
struct MessageLinkTests {
  @Test("Answers link by turn, prompts by item, previews not at all")
  func links() throws {
    let session = try #require(URL(string: "https://omni.example/c/conv_1"))
    let answer = Row(id: "msg_2", role: .assistant, responseId: "resp_9")
    #expect(
      ConversationContainer.messageURL(answer, in: session)?.absoluteString
        == "https://omni.example/c/conv_1?message=resp_9")
    let prompt = Row(id: "msg_1", role: .user, responseId: "resp_9")
    #expect(
      ConversationContainer.messageURL(prompt, in: session)?.absoluteString
        == "https://omni.example/c/conv_1?message=msg_1")
    #expect(
      ConversationContainer.messageURL(
        Row(id: "live:x", role: .assistant, isEphemeral: true), in: session) == nil)
    #expect(ConversationContainer.messageURL(answer, in: nil) == nil)
  }
}

@Suite("Context usage")
struct ContextUsageTests {
  private func usage(_ details: [(String, String)]) -> OmnigentCoreFFI.EventSection {
    OmnigentCoreFFI.EventSection(
      id: "usage", title: "Usage", summary: "",
      details: details.map {
        OmnigentCoreFFI.DetailSection(id: $0.0, title: $0.0, text: $0.1, isCode: false)
      }, sessionId: nil)
  }

  @Test("The gauge needs both tokens and a window, and stays within 0...1")
  func fraction() {
    #expect(
      ComposerAdapter.contextFraction([
        usage([("context_tokens", "50000"), ("context_window", "200000")])
      ]) == 0.25)
    #expect(
      ComposerAdapter.contextFraction([
        usage([("context_tokens", "300000"), ("context_window", "200000")])
      ]) == 1)
    #expect(ComposerAdapter.contextFraction([usage([("context_tokens", "5")])]) == nil)
    #expect(
      ComposerAdapter.contextFraction([
        usage([("context_tokens", "5"), ("context_window", "0")])
      ]) == nil)
    #expect(ComposerAdapter.contextFraction([]) == nil)
  }
}
