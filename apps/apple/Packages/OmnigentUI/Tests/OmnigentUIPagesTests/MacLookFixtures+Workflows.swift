import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// The Tasks tab's stopping run and a step's Markdown description, and an automation that can't
/// be shared and a new one that can't be created yet.
extension LookFixtures {
  static var tasksStopping: some View {
    let started = now.addingTimeInterval(-300)
    let list = TaskListState(
      planName: "Ship the JSON flag", updatedAt: started, summary: "1 of 3 finished",
      counts: [TaskCountLine(state: .running, text: "1 running")], isStopping: true,
      fromPlan: true,
      rows: [
        TaskRowState(
          id: "build", number: 1, name: "Build", state: .done, stateLabel: "Done",
          detail: .text("Compiled"), endedAt: started),
        TaskRowState(
          id: "test", number: 2, name: "Run the tests", state: .running, stateLabel: "Running",
          detail: .text("Running the suite"), runningSince: started),
        TaskRowState(
          id: "ship", number: 3, name: "Ship it", state: .waiting, stateLabel: "Not started",
          detail: .text("Inputs: the green build. Open the change for review"),
          dependsOn: ["Run the tests"]),
      ])
    return TasksPanel(
      content: TasksPanelContent(
        state: .loaded(list), taskToShow: nil, perform: { _, _ in }, stop: {},
        continuePlan: {}, showInChat: { _ in }, retry: {}, shown: {}))
  }

  static let stepGoal = """
    **Inputs:** the pull request named in the run's request, and its CI checks.

    **What it does:**
    - Reads the logs of each failing check, including the ones that time out after a long wait
    - Fixes the cause and pushes

    **Outputs:** the pull request with passing checks.

    **Details:** list the checks with `gh pr checks <number> --json name,state`.
    """

  static var taskHistory: some View {
    let started = now.addingTimeInterval(-600)
    let row = TaskRowState(
      id: "fix", number: 2, name: "Fix the failing checks", state: .running,
      stateLabel: "Running", detail: .started(since: started, text: "Reading the logs"),
      runningSince: started, dependsOn: ["Build"], goal: stepGoal,
      history: [
        TaskHistoryLine(
          id: "s1", label: "Started", state: .running, text: "Reading the logs", date: started,
          restarted: false)
      ])
    return TaskHistoryView(row: row).padding(Theme.Spacing.medium)
  }

  static var legacyShareDetail: some View {
    var state = AutomationUXFixtures.detail
    state.shareDisabledReason = "This is a legacy automation. Recreate it to share it."
    return AutomationDetailView(state: state, actions: AutomationUXFixtures.detailActions)
  }

  static var newAutomation: some View {
    AutomationEditorSheet(
      draft: .constant(AutomationUXFixtures.scheduleDraft),
      context: AutomationUXFixtures.editorContext(), save: {}, cancel: {})
  }
}
