import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// Why the automation editor's Create or Save changes is off.
@Suite("Automation editor: what Save still needs")
struct AutomationSaveBlockerTests {
  @MainActor
  @Test("Create says what it still needs, in the form's order")
  func saveBlockers() {
    func reason(
      _ draft: AutomationDraftState, editing: Bool = false,
      _ change: (inout AutomationEditorContext) -> Void = { _ in }
    ) -> String? {
      var context = AutomationEditorContext(
        agents: [], supportsSessionModes: false, describe: { _ in "" }, isEditing: editing)
      change(&context)
      let sheet = AutomationEditorSheet(
        draft: .constant(draft), context: context, save: {}, cancel: {})
      #expect(sheet.canSave == (sheet.saveBlockedReason == nil && !context.isSaving))
      return sheet.saveBlockedReason
    }
    var draft = AutomationDraftState()
    #expect(reason(draft) == "Enter a name in the field at the top.")
    draft.name = "Brief"
    #expect(reason(draft) == "Add instructions.")
    // A new automation's schedule sits above its instructions.
    #expect(reason(draft) { $0.scheduleProblem = "Pick a day." } == "Pick a day.")
    draft.prompt = "Summarize"
    #expect(reason(draft) { $0.blocker = "Pick a host." } == "Pick a host.")
    #expect(reason(draft) == "Pick an agent.")
    draft.agentID = "a1"
    #expect(reason(draft) == nil)
    // An edit's schedule is under Advanced settings, after the MCP services.
    #expect(
      reason(draft, editing: true) {
        $0.scheduleProblem = "Pick a day."
        $0.mcpProblem = "Sign in."
      } == "Sign in.")
    #expect(reason(draft) { $0.costLimitProblem = "Too low." } == "Too low.")
    #expect(reason(draft) { $0.isSaving = true } == nil)
    draft.trigger = AutomationTriggerDraft(source: "jira", event: "created")
    #expect(reason(draft) == "Fill in the trigger\u{2019}s required fields and instructions.")
    #expect(
      reason(draft) {
        $0.triggerPrompt = "Watch Jira."
        $0.triggerScheduleUnsupported = true
        $0.scheduleProblem = "Too often."
      } == "Use a supported schedule.")
  }
}
