import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The Workflows pages' rows from the core's records: a run's line, control and the runs below
/// it, the steps' graph, and the automations that run a workflow.
@MainActor
@Suite("Workflows mapping")
struct WorkflowsMappingTests {
  private let workflowID = "0123456789abcdef0123456789abcdef"

  private func step(_ id: String, _ dependsOn: [String] = []) -> PlanStep {
    PlanStep(id: id, name: id.uppercased(), goal: "**Goal** of \(id)", dependsOn: dependsOn)
  }

  private func status(_ position: Int64, _ step: String, _ status: StepStatus) -> JournalEntry {
    JournalEntry(
      id: "s\(position)", position: position, createdAt: 100 + position,
      scheduledTaskRunId: nil, step: step, kind: "status", workflowId: nil, status: status,
      text: nil, name: nil, steps: [], version: nil, graphRevision: .text(value: "g"))
  }

  private func run(_ id: String, running: Bool, descendants: [WorkflowRun] = []) -> WorkflowRun {
    WorkflowRun(
      id: id, workflowId: workflowID, planGraphRevision: .text(value: "g"),
      sessionId: "session_\(id)", title: id == "nested" ? "" : "Run \(id)", startedAt: 1_000,
      isCurrent: true, sessionStatus: running ? .running : .idle, backgroundWorkRunning: false,
      sandboxLaunching: false, archived: false,
      progress: RunProgress(total: 2, started: 1, done: 1, needsInput: 0, failed: 0),
      steps: [step("a"), step("b", ["a"])],
      statuses: [status(1, "a", .done), status(2, "b", .started)],
      workflowName: "Triage",
      startedBy: RunStarter(sessionId: "parent", title: "Nightly"),
      descendantRuns: descendants, descendantRunCount: UInt32(descendants.count),
      descendantRunsCursor: descendants.isEmpty ? nil : "more", descendantRunsActive: false)
  }

  private func context(stopping: Set<String> = []) -> WorkflowsMapping.RunContext {
    WorkflowsMapping.RunContext(
      workflowID: workflowID, stopping: stopping, acting: [], parentSessionID: nil,
      descendants: { $0.descendantRuns }, hasMoreDescendants: { $0.descendantRunsCursor != nil },
      loadingDescendants: [])
  }

  @Test("a working run shows its count, Stop, its starter and its steps' states")
  func workingRun() {
    let row = WorkflowsMapping.run(run("r", running: true), owned: true, context: context())
    #expect(row.stateLabel == "1 of 2 done")
    #expect(row.glyph == .running)
    #expect(row.control == .stop)
    #expect(row.startedBy?.title == "Nightly")
    #expect(row.steps.map(\.state) == [.done, .running])
    #expect(row.steps.last?.action?.kind == .stop)
    let stopping = WorkflowsMapping.run(
      run("r", running: true), owned: true, context: context(stopping: ["r"]))
    #expect(stopping.control == .stopping)
    #expect(stopping.steps.last?.action == nil, "no second Stop")
    let theirs = WorkflowsMapping.run(run("r", running: true), owned: false, context: context())
    #expect(theirs.control == nil)
  }

  @Test("the runs below a run list under Ran N workflows, without a Started by")
  func descendants() throws {
    let parent = run("p", running: false, descendants: [run("nested", running: true)])
    let row = WorkflowsMapping.run(parent, owned: true, context: context())
    let below = try #require(row.descendants)
    #expect(below.label == "Ran 1 workflow")
    #expect(below.startsOpen, "one of them works")
    #expect(below.hasMore)
    let nested = below.rows.first
    #expect(nested?.title == "Untitled session")
    #expect(nested?.startedBy?.title == "Nightly", "its starter isn't the parent here")
    #expect(nested?.workflowLinkID == workflowID)
    #expect(row.control == .play, "it stopped with a task left")
  }

  @Test("the graph places each step by dependency with a plain preview")
  func graph() {
    let graph = WorkflowsMapping.graph([step("a"), step("b", ["a"]), step("c", ["a"])])
    #expect(graph.rows == 2 && graph.columns == 2)
    #expect(graph.steps.map(\.row) == [0, 1, 1])
    #expect(graph.steps.first?.goalPreview == "Goal of a")
    #expect(graph.edges.map(\.to) == ["b", "c"])
  }

  @Test("only the automations that run the workflow list, with their schedule")
  func automations() {
    let runs = savedWorkflowMessage(
      skillPrefix: "/", workflowId: workflowID, workflowName: "Triage", details: "",
      reviewPlanFirst: false)
    func automation(_ id: String, prompt: String) -> Automation {
      Automation(
        id: id, name: "Automation \(id)", prompt: prompt, rrule: "FREQ=DAILY",
        scheduleText: "Every day at 9:00 AM", agentId: "agent", timezone: "UTC",
        continuesSession: false, state: .active, nextRunAt: nil, lastRunAt: nil,
        lastRunStatus: nil, lastRunSessionId: nil, updatedAt: 0)
    }
    let load = CreationLoad<[Automation]>.loaded([
      automation("a", prompt: runs), automation("b", prompt: "Summarize the news"),
    ])
    guard
      case .loaded(let rows) = WorkflowsMapping.automations(load, workflowID: workflowID, now: .now)
    else {
      Issue.record("not loaded")
      return
    }
    #expect(rows.map(\.id) == ["a"])
    #expect(rows.first?.schedule == "Every day at 9:00 AM")
    #expect(
      WorkflowsMapping.automationNames([automation("a", prompt: runs)], running: workflowID)
        == ["Automation a"])
  }
}
