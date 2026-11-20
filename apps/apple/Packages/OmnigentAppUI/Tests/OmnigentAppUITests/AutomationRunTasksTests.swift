import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// An automation run's plan on its history row (web `RunRow` with run steps): the tasks, the
/// agent's last words, the plan's control, and the session activity a later run hides.
@MainActor
@Suite("Automation run tasks")
struct AutomationRunTasksTests {
  private let now = Date(timeIntervalSince1970: 1_793_865_600)
  private let session = "fedcba9876543210fedcba9876543210"
  private let plan = "0123456789abcdef0123456789abcdef"

  private func run(sessionRunning: Bool = false) -> AutomationRun {
    AutomationRun(
      id: "run-1", status: .succeeded, inFlightLabel: nil, startedAt: 1_793_860_000,
      duration: nil, sessionId: session, failureStage: nil, failureReason: nil, unread: false,
      needsApproval: true, sessionRunning: sessionRunning)
  }

  private func steps(
    isCurrent: Bool, planID: String?, status: StepStatus = .done, text: String = "Built"
  ) -> AutomationRunSteps {
    let written = JournalEntry(
      id: "s1", position: 4, createdAt: 1, scheduledTaskRunId: "run-1", step: "build",
      kind: "status", workflowId: nil, status: status, text: text, name: nil, steps: [],
      version: nil, graphRevision: nil)
    return AutomationRunSteps(
      runId: "run-1", planId: planID, planGraphRevision: .text(value: "graph-1"),
      isCurrent: isCurrent, workflowId: "wf-1", planName: "Fix the build",
      steps: [
        PlanStep(id: "build", name: "Build", goal: nil, dependsOn: []),
        PlanStep(id: "ship", name: "Ship", goal: nil, dependsOn: ["build"]),
      ],
      statuses: [written])
  }

  private func row(
    _ run: AutomationRun, steps: AutomationRunSteps, working: Bool, stopping: Set<String> = []
  ) -> AutomationRunRow {
    var context = AutomationDetailMapping.RunTasksContext()
    context.sessionWorking = { _ in working }
    var row = AutomationDetailMapping.row(run, now: now, calendar: .current, steps: steps)
    AutomationDetailMapping.addTasks(
      steps, of: run, to: &row, context: context, stopping: stopping)
    return row
  }

  @Test("A working run's plan shows its tasks, Stop, its workflow and the agent's last words")
  func workingPlan() {
    let current = steps(isCurrent: true, planID: plan, status: .failed, text: "CI is down")
    let row = row(run(sessionRunning: true), steps: current, working: true)
    #expect(row.tasks?.id == plan)
    #expect(row.tasks?.steps.map(\.name) == ["Build", "Ship"])
    #expect(row.tasks?.control == .stop)
    #expect(row.tasks?.workflowLinkID == "wf-1")
    #expect(row.tasks?.title == "Fix the build")
    #expect(
      row.statusText
        == AutomationRunStatusText(label: "Failed", text: "CI is down", isFailure: true))
    #expect(row.indicator == .sessionRunning)
    #expect(row.statusLabel == "Session running")
    #expect(row.needsApproval)
  }

  @Test("A stopped plan offers Continue, and a Stop in flight reads Stopping")
  func stoppedPlan() {
    let idle = row(run(), steps: steps(isCurrent: true, planID: plan), working: false)
    #expect(idle.tasks?.control == .play)
    #expect(
      idle.statusText == AutomationRunStatusText(label: "Done", text: "Built", isFailure: false))
    let stopping = row(
      run(sessionRunning: true), steps: steps(isCurrent: true, planID: plan), working: true,
      stopping: [plan])
    #expect(stopping.tasks?.control == .stopping)
  }

  @Test("A plan the session has moved past hides the session's activity and takes no actions")
  func earlierPlan() {
    let row = row(
      run(sessionRunning: true), steps: steps(isCurrent: false, planID: plan), working: true)
    #expect(row.tasks?.control == nil)
    #expect(row.tasks?.steps.allSatisfy { $0.action == nil } == true)
    #expect(row.indicator == .completed)
    #expect(row.statusLabel == nil)
    #expect(!row.needsApproval)
  }

  @Test("An older server's plan without an entry id shows its tasks but no control")
  func noPlanID() {
    let row = row(run(), steps: steps(isCurrent: true, planID: nil), working: false)
    #expect(row.tasks?.steps.count == 2)
    #expect(row.tasks?.control == nil)
    #expect(row.tasks?.steps.allSatisfy { $0.action == nil } == true)
  }
}
