import Testing

@testable import OmnigentUIComponents

/// What a trigger's worker fields say, as the web's `TriggerWorkerSettingsFields`.
@Suite("Automation worker wording")
struct AutomationWorkerTextTests {
  @Test("The footer names who takes the settings, then what Default and the modes mean")
  func footer() {
    #expect(
      AutomationWorkerText.footer(
        creating: true, taskSession: false, followsPolling: true, inheritsPolling: false,
        offersModes: true)
        == "Each session started for a matching item uses these. They match the polling session until you change them. Default uses the selected harness\u{2019}s configuration. Modes that skip approval aren\u{2019}t available here."
    )
    let edit = AutomationWorkerText.footer(
      creating: false, taskSession: true, followsPolling: false, inheritsPolling: true,
      offersModes: false)
    #expect(edit.hasPrefix("Applies to the next task session."))
    #expect(
      edit.hasSuffix("Pick another mode so they don\u{2019}t run in the polling session\u{2019}s."))
  }

  @Test("The group and notes follow the session mode")
  func names() {
    #expect(AutomationWorkerText.groupName(taskSession: true) == "Task session")
    #expect(AutomationWorkerText.groupName(taskSession: false) == "Matching sessions")
    #expect(
      AutomationWorkerText.pollingNote(reusesSession: false)
        == "The next run starts a new polling session with these.")
    #expect(
      AutomationWorkerText.unapplied("plan", modesApply: false)
        == "Matching sessions are set to start in plan, which this server can\u{2019}t apply, so they won\u{2019}t start."
    )
  }
}
