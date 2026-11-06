import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Composer: approval modes, agent-first configuration, context and send intent")
struct ComposerRulesTests {
  // MARK: Approval modes

  @Test("Modes read as states with shield symbols; the riskiest is full access")
  func modePresentation() {
    let codex = ComposerSamples.codexModes()
    #expect(codex.selected?.label == "Auto-approve")
    #expect(codex.selected?.harnessLabel == "Approve for me")
    #expect(codex.options.map(\.label) == ["Auto-edit", "Auto-approve", "Full access"])
    #expect(codex.options.map(\.risk).max() == .fullAccess)
    for risk in ApprovalRisk.allCases {
      #expect(risk.systemImage.contains("shield"))
    }
    #expect(ApprovalModeChip.shortName("Full access") == "Full")
    #expect(ApprovalModeChip.shortName("Auto-edit") == "Auto-edit")
  }

  @Test("Shift-Tab skips launch-only modes and never leaves an unknown or launch-only mode")
  func modeCycling() {
    var modes = ComposerSamples.claudeModes()
    modes.options.append(
      ApprovalModeOption(
        id: "bypassPermissions", label: "Full access", risk: .fullAccess, isSwitchable: false))
    modes.selectedID = "auto"
    #expect(modes.next?.id == "default", "wraps past the launch-only mode")
    modes.selectedID = "bypassPermissions"
    #expect(modes.next == nil)
    modes.selectedID = nil
    #expect(modes.next == nil)
    #expect(modes.selected == nil)
  }

  // MARK: Agent, model, effort

  @Test("A default always says what it resolves to")
  func defaultLabels() {
    let codex = ComposerSamples.codexConfiguration
    #expect(codex.defaultModelTitle == "Default (GPT-5.2 Codex)")
    #expect(codex.modelTitle == "GPT-5.2 Codex")
    #expect(codex.isModelInherited)
    #expect(codex.defaultEffortTitle == "Default (Medium)")
    #expect(codex.title == "Codex \u{00B7} GPT-5.2 Codex \u{00B7} High")

    let reported = ComposerConfiguration(
      harness: "codex-native",
      modelOptions: [ModelOption(id: "gpt-5.2", displayName: "GPT-5.2")], baseModel: "gpt-5.2")
    #expect(reported.defaultModelTitle == "Default (GPT-5.2)")
    let raw = ComposerConfiguration(harness: "codex-native", baseModel: "gpt-6-preview")
    #expect(raw.defaultModelTitle == "Default (gpt-6-preview)")

    let unknown = ComposerConfiguration(harness: "claude-native")
    #expect(unknown.defaultModelTitle == "Agent default")
    #expect(unknown.modelTitle == "Agent default")
    #expect(unknown.defaultEffortTitle == "Agent default")
    #expect(unknown.effortTitle == nil)
    #expect(unknown.agentTitle == "Claude Code")
    for title in [codex.defaultModelTitle, unknown.defaultModelTitle, unknown.modelTitle] {
      #expect(title != "Default")
    }
  }

  @Test("Only the selected agent's models and the selected model's efforts are offered")
  func validity() {
    var codex = ComposerSamples.codexConfiguration
    #expect(codex.visibleModels.map(\.id) == ["gpt-5.2-codex", "gpt-5.2"])
    #expect(codex.canSelect(model: nil))
    #expect(codex.canSelect(model: "gpt-5.2"))
    #expect(!codex.canSelect(model: "o4-mini"), "hidden")
    #expect(!codex.canSelect(model: "claude-opus"), "another agent's model")
    #expect(codex.efforts == ["low", "medium", "high"])
    #expect(codex.effortKept(selecting: "gpt-5.2") == "high")
    codex.selectedEffort = "minimal"
    #expect(codex.effortKept(selecting: "gpt-5.2") == "minimal")
    #expect(codex.effortKept(selecting: "gpt-5.2-codex") == nil)

    codex.selectedModelId = "claude-opus"
    codex.selectedEffort = "max"
    let validated = codex.validated
    #expect(validated.selectedModelId == nil)
    #expect(validated.selectedEffort == nil)
  }

  @Test("Agents that cannot run say why, and the chip names the agent first")
  func agents() {
    let codex = ComposerSamples.codexConfiguration
    #expect(codex.selectedAgent?.name == "Codex")
    #expect(codex.harnessChoices.first { $0.id == "agent_pi" }?.unavailableReason != nil)
    #expect(codex.title.hasPrefix("Codex"))
  }

  // MARK: Execution context

  @Test("The context line is agent, host, repository and branch")
  func contextSummary() {
    let context = ComposerSamples.context
    #expect(context.summary() == "Codex \u{00B7} Mac Studio \u{00B7} omnigent / auth-refresh")
    #expect(context.summary(includingWorkspace: false) == "Codex \u{00B7} Mac Studio")
    #expect(ExecutionContext().summary() == "Execution context")
    #expect(ExecutionContext(directory: "/").repository == "/")
  }

  @Test("Servers show their display name, never a loopback address")
  func serverNames() {
    #expect(
      ExecutionContext.serverDisplayName(name: "Team", baseURL: "http://127.0.0.1:6767")
        == "Team")
    let mac = "This Mac"
    func name(_ name: String?, _ baseURL: String?, loopback: String? = mac) -> String {
      ExecutionContext.serverDisplayName(name: name, baseURL: baseURL, loopbackName: loopback)
    }
    #expect(name(nil, "http://127.0.0.1:6767") == mac)
    #expect(name(" ", "http://[::1]:6767/omnigent") == mac)
    #expect(name("localhost", "not a url") == mac)
    #expect(name(nil, "https://omni.example.com:8443/x") == "omni.example.com:8443")
    #expect(name(nil, nil) == "Connected server")
    // On iPhone and iPad a loopback server shows its address, never "This device".
    #expect(name(nil, "http://127.0.0.1:6767", loopback: nil) == "127.0.0.1:6767")
    #expect(name("localhost", "http://localhost:6767", loopback: nil) == "localhost:6767")
    #expect(name("localhost", "not a url", loopback: nil) == "localhost")
    #if os(macOS)
      #expect(ExecutionContext.serverDisplayName(name: nil, baseURL: "http://[::1]:1") == mac)
      #expect(ExecutionContext.hostDisplayName("127.0.0.1") == mac)
    #else
      #expect(ExecutionContext.hostDisplayName("127.0.0.1") == "127.0.0.1")
    #endif
    #expect(ExecutionContext.hostDisplayName("127.example.com") == "127.example.com")
    #expect(ExecutionContext.hostDisplayName("") == nil)
  }

  // MARK: Send intent

  @Test("Send says what it does while the agent works, keeping the queue's order")
  func intents() {
    typealias Intent = ComposerSendIntent
    #expect(
      Intent.resolve(isRunning: false, canSteer: true, hasQueue: false, canQueue: true) == .send)
    #expect(
      Intent.resolve(isRunning: true, canSteer: true, hasQueue: false, canQueue: true) == .steer)
    #expect(
      Intent.resolve(isRunning: true, canSteer: false, hasQueue: false, canQueue: true) == .queue)
    #expect(
      Intent.resolve(isRunning: true, canSteer: true, hasQueue: true, canQueue: true) == .queue)
    #expect(
      Intent.resolve(isRunning: false, canSteer: true, hasQueue: true, canQueue: true) == .queue)
    #expect(
      Intent.resolve(
        isRunning: true, canSteer: true, hasQueue: false, canQueue: true, prefersSteer: false)
        == .queue)
    #expect(
      Intent.resolve(isRunning: true, canSteer: false, hasQueue: false, canQueue: false) == .queue)
    #expect(Intent.steer.label == "Send now \u{00B7} steer")
    #expect(Intent.queue.label == "Queued \u{00B7} after this turn")
    #expect(Intent.send.label == nil)
    #expect(Intent.steer.alternative(canSteer: true, canQueue: true) == .queue)
    #expect(Intent.queue.alternative(canSteer: true, canQueue: true) == .steer)
    #expect(Intent.queue.alternative(canSteer: false, canQueue: true) == nil)
    #expect(Intent.send.alternative(canSteer: true, canQueue: true) == nil)
  }

  @Test("Queued messages carry attachments, as steered ones do; uploads must finish first")
  func blockedReasons() {
    var state = ComposerSamples.running
    state.queue = []
    state.attachments = [DraftAttachment(id: "a", title: "trace.json", kind: .file)]
    let rules = ComposerSendRules(state: state, draft: "see attached", canQueue: true)
    #expect(rules.intent == .steer)
    #expect(rules.blockedReason(for: .steer) == nil)
    #expect(rules.blockedReason(for: .queue) == nil)
    state.attachments[0].state = .uploading(progress: nil)
    let uploading = ComposerSendRules(state: state, draft: "see attached", canQueue: true)
    #expect(uploading.blockedReason(for: .queue) == "Waiting for attachments to upload.")
    #expect(
      rules.placeholder
        == "Steer the agent \u{2014} \u{21B5} to send now, \u{2325}\u{2318}\u{21B5} to queue for later, "
        + "Esc to stop")
    let empty = ComposerSendRules(state: ComposerSamples.idle, draft: " ", canQueue: true)
    #expect(empty.sendBlockedReason == "Type a message.")
    var quoting = ComposerSamples.idle
    quoting.quotes = [ComposerQuote(text: "the error above")]
    let quoted = ComposerSendRules(state: quoting, draft: "", canQueue: true)
    #expect(quoted.sendBlockedReason == nil && quoted.hasContent)
  }

  @Test("With Always steer off, a mid-turn send queues and steering is the alternative")
  func alwaysSteerOff() {
    var state = ComposerSamples.running
    state.queue = []
    state.canSteer = true
    state.prefersSteer = false
    let rules = ComposerSendRules(state: state, draft: "next", canQueue: true)
    #expect(rules.intent == .queue)
    #expect(rules.alternative == .steer)
    state.prefersSteer = true
    #expect(ComposerSendRules(state: state, draft: "next", canQueue: true).intent == .steer)
  }
}
