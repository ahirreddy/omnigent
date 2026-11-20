import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A new side chat's model and effort, chosen over the session it forks.
@Suite("Side chat: first-turn model and effort")
struct SideChatSettingsTests {
  private let parent: ComposerConfiguration = {
    var configuration = ComposerConfiguration(
      harness: "claude-sdk",
      harnessChoices: [HarnessChoice(id: "agent_codex", name: "Codex", harness: "codex")],
      modelOptions: [ModelOption(id: "opus"), ModelOption(id: "sonnet")],
      selectedModelId: "opus", selectedEffort: "high")
    configuration.smartRouting = .enabled
    return configuration
  }()

  @Test func theTabsChoiceShowsOverTheSessionsAndNothingElseIsOffered() {
    var draft = SideChatDrafts.Draft()
    let inherited = PendingSideChatTab.choice(over: parent, draft: draft)
    #expect(inherited.selectedModelId == "opus", "the session's model until one is chosen")
    #expect(inherited.harnessChoices.isEmpty, "the side chat runs the session's agent")
    #expect(inherited.smartRouting == .unavailable)
    draft.model = "sonnet"
    draft.effort = "low"
    draft.isStarting = true
    let chosen = PendingSideChatTab.choice(over: parent, draft: draft)
    #expect(chosen.selectedModelId == "sonnet")
    #expect(chosen.selectedEffort == "low")
    #expect(chosen.isApplying, "the menus wait while it starts")
  }
}
