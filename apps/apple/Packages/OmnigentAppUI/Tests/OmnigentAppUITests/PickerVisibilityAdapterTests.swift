import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct PickerVisibilityAdapterTests {
  private func agent(
    _ name: String, harness: String, section: AgentPickerSection, label: String = "",
    primary: Bool = false
  ) -> OmnigentCoreFFI.CreationAgent {
    OmnigentCoreFFI.CreationAgent(
      id: "id-\(name)", name: name, harness: harness, description: nil, harnessLabel: label,
      supportsCreation: true, pickerSection: section, isPrimaryHarness: primary)
  }

  private var catalog: OmnigentCoreFFI.CreationCatalog {
    OmnigentCoreFFI.CreationCatalog(
      hosts: [],
      agents: [
        agent("polly", harness: "claude-sdk", section: .agent),
        agent(
          "claude-native-ui", harness: "claude-native", section: .harness, label: "Claude Code",
          primary: true),
        agent("mine", harness: "openai-agents", section: .custom),
      ])
  }

  @Test func entriesListHarnessesByLabelThenAgentsByName() {
    let entries = PickerVisibilityAdapter.entries(catalog)
    #expect(entries.map(\.name) == ["claude-native-ui", "polly", "mine"])
    #expect(entries.map(\.title) == ["Claude Code", "polly", "mine"])
    #expect(entries.map(\.group) == [.harnesses, .agents, .agents])
  }

  @Test func pickersDropHiddenAgentsButKeepTheSelectedOne() {
    let shown = PickerVisibilityAdapter.shown(
      catalog.agents, selectedID: "id-mine", hidden: ["polly", "mine"])
    #expect(shown.map(\.name) == ["claude-native-ui", "mine"])
  }

  @Test func contextTokensComeFromTheUsageSection() {
    let usage = OmnigentCoreFFI.EventSection(
      id: "usage", title: "Usage", summary: "",
      details: [("context_tokens", "76000"), ("context_window", "200000")].map {
        OmnigentCoreFFI.DetailSection(id: $0.0, title: $0.0, text: $0.1, isCode: false)
      }, sessionId: nil)
    #expect(
      ComposerAdapter.contextTokens([usage]) == ContextTokens(used: 76_000, window: 200_000))
    #expect(ComposerAdapter.contextTokens([]) == nil)
  }
}
