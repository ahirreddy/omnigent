import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The inspector and the composer name the session's approval mode the same way.
@MainActor
@Suite("Approval mode title")
struct ApprovalModeTitleTests {
  @Test("the inspector's title is the chip's name for the mode")
  func titleMatchesTheChip() async throws {
    let store = try await ConversationFixtures.store()
    #expect(ConversationAdapter.approvalModeTitle(store) == nil)
    var configuration = ConversationFixtures.configuration(
      harness: "codex-native", wrapper: "codex-native-ui")
    configuration.approvalMode = "approve-for-me"
    store.composer.configuration = configuration
    #expect(ConversationAdapter.approvalModeTitle(store) == "Auto-approve")
    #expect(
      ConversationAdapter.screenState(store, summary: nil).approvalModeTitle == "Auto-approve")
    #expect(ConversationAdapter.state(store, summary: nil).approvalModeTitle == "Auto-approve")
  }
}

/// The inspector names the same reasoning effort as the composer's chip.
@MainActor
@Suite("Effort title")
struct EffortTitleTests {
  private func configuration(effort: String?) -> SessionConfiguration {
    var configuration = ConversationFixtures.configuration(
      harness: "codex-native", wrapper: "codex-native-ui")
    configuration.effort = effort
    configuration.baseModel = "gpt"
    configuration.models = [
      ModelChoice(
        id: "gpt", model: "gpt", displayName: "GPT", description: nil, hidden: false,
        isDefault: true, defaultReasoningEffort: "low",
        supportedReasoningEfforts: [
          ReasoningChoice(reasoningEffort: "low", description: nil),
          ReasoningChoice(reasoningEffort: "high", description: nil),
        ], title: "GPT", value: "gpt")
    ]
    return configuration
  }

  @Test("with no choice made, both name the model's default effort")
  func defaultEffortAgrees() async throws {
    let store = try await ConversationFixtures.store()
    #expect(ConversationAdapter.screenState(store, summary: nil).effortTitle == nil)
    store.composer.configuration = configuration(effort: nil)
    let chip = ComposerAdapter.configuration(store.composer).effortTitle
    #expect(chip == "Low")
    #expect(ConversationAdapter.screenState(store, summary: nil).effortTitle == chip)
    #expect(ConversationAdapter.state(store, summary: nil).effortTitle == chip)
  }

  @Test("a chosen effort reads the same in both")
  func chosenEffortAgrees() async throws {
    let store = try await ConversationFixtures.store()
    store.composer.configuration = configuration(effort: "high")
    #expect(ConversationAdapter.screenState(store, summary: nil).effortTitle == "High")
    #expect(ComposerAdapter.configuration(store.composer).effortTitle == "High")
  }
}
