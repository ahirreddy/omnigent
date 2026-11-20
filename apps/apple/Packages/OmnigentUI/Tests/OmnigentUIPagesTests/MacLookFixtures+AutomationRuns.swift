import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// An automation's runs following a plan, and a trigger's Instructions tab with a workflow.
extension LookFixtures {
  /// The run history: a working run with its tasks and Stop, a finished one that says what its
  /// agent last wrote, and one whose task failed.
  static var automationRunTasks: some View {
    var state = AutomationUXFixtures.detail
    let started = now.addingTimeInterval(-900)
    var working = AutomationRunRow(id: "r1", indicator: .inFlight, timestamp: "Today, 9:00 AM")
    working.statusLabel = "Running"
    working.sessionID = "s1"
    working.statusText = AutomationRunStatusText(
      label: "Started", text: "Reading the failing checks", isFailure: false)
    working.tasks = runTasks(
      id: "p1", states: [.done, .running, .waiting], control: .stop, started: started)
    var finished = AutomationRunRow(
      id: "r2", indicator: .unread, timestamp: "Yesterday, 9:00 AM")
    finished.duration = "6m 40s"
    finished.sessionCost = "Session cost $1.12"
    finished.sessionID = "s2"
    finished.statusText = AutomationRunStatusText(
      label: "Done", text: "Opened 2 PRs", isFailure: false)
    finished.tasks = runTasks(
      id: "p2", states: [.done, .done, .done], control: nil, started: started)
    var failed = AutomationRunRow(id: "r3", indicator: .completed, timestamp: "Nov 17, 9:00 AM")
    failed.duration = "2m 05s"
    failed.sessionID = "s3"
    failed.statusText = AutomationRunStatusText(
      label: "Failed", text: "CI is down, so the checks never ran", isFailure: true)
    failed.tasks = runTasks(
      id: "p3", states: [.done, .failed, .waiting], control: .play, started: started)
    state.runs = [working, finished, failed]
    var actions = AutomationUXFixtures.detailActions
    actions.runTasks.openSession = { _ in }
    actions.runTasks.openTask = { _, _ in }
    actions.runTasks.openWorkflow = { _ in }
    actions.runTasks.runControl = { _, _ in }
    return AutomationDetailView(state: state, actions: actions).omnigentAppearance(.omni)
  }

  private static func runTasks(
    id: String, states: [TaskState], control: WorkflowRunControl?, started: Date
  ) -> WorkflowRunRowState {
    let names = ["Read the checks", "Fix the failures", "Open the pull request"]
    var tasks = WorkflowRunRowState(
      id: id, sessionID: "s-\(id)", title: "Fix flaky checks", startedAt: started,
      glyph: .waiting, stateLabel: "")
    tasks.steps = zip(names.indices, zip(names, states)).map { index, pair in
      var step = WorkflowStepState(
        id: "step\(index)", number: index + 1, name: pair.0, goal: nil, row: index,
        halfColumn: 0)
      step.state = pair.1
      return step
    }
    tasks.graph = WorkflowGraphState(
      steps: tasks.steps,
      edges: [.init(from: "step0", to: "step1"), .init(from: "step1", to: "step2")],
      rows: 3, columns: 1)
    tasks.control = control
    tasks.workflowLinkID = "wf_checks"
    return tasks
  }

  /// A trigger's Instructions tab with a saved workflow chosen and room for its details.
  static var triggerWorkflow: some View {
    var draft = AutomationUXFixtures.triggerDraft
    draft.workflow = AutomationOption(id: "wf_triage", name: "Triage new tickets")
    draft.workflowDetailsID = "wf_triage"
    draft.trigger?.instructions = "Only tickets labeled needs-triage."
    return Form {
      AutomationTriggerInstructions(
        trigger: .constant(draft.trigger ?? AutomationTriggerDraft(source: "", event: "")),
        template: AutomationUXFixtures.triggerTemplate,
        renderedPrompt: "Every check, list the new tickets in ENG labeled needs-triage.",
        workflowField: AutomationWorkflowField(
          draft: .constant(draft),
          workflows: [
            AutomationOption(id: "wf_triage", name: "Triage new tickets"),
            AutomationOption(id: "wf_release", name: "Draft release notes"),
          ]),
        instructionsAreDetails: true, editAsPrompt: {})
    }
    .formStyle(.grouped)
    .omnigentAppearance(.omni)
  }
}
