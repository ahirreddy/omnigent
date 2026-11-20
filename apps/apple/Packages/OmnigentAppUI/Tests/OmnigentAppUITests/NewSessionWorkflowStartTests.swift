import Foundation
import OmnigentCoreFFI
import OmnigentStores
import Testing

@testable import OmnigentAppUI

/// What the new-session page sends for a saved workflow: a run sends its request; a planning
/// chat on a host keeps its prompt as the chat's draft, as the web's planning chat does.
@MainActor
struct NewSessionWorkflowStartTests {
  private let target = WorkflowLaunchTarget(
    id: "0123456789abcdef0123456789abcdef", name: "Triage", description: "")

  @Test("A planning chat on a host sends nothing and keeps its prompt for the chat")
  func planOnHost() {
    let form = NewSessionForm()
    form.workflow = NewSessionWorkflow(launch: .plan(target, prompt: "Draft the plan."))
    var selection = form.selection
    let start = form.workflowStart(text: "Draft the plan.", selection: &selection)
    #expect(start.title == "Plan workflow: Triage")
    #expect(start.message.isEmpty)
    #expect(form.workflow?.plannerDraft == "Draft the plan.")
  }

  @Test("A planning chat in a sandbox sends its prompt once the sandbox is up")
  func planInSandbox() {
    let form = NewSessionForm()
    form.isSandbox = true
    form.workflow = NewSessionWorkflow(launch: .plan(target, prompt: "Draft the plan."))
    var selection = form.selection
    let start = form.workflowStart(text: "Draft the plan.", selection: &selection)
    #expect(start.message == "Draft the plan.")
    #expect(form.workflow?.plannerDraft == nil)
  }

  @Test("A run sends its request and files the session under its workflow")
  func run() {
    let form = NewSessionForm()
    form.workflow = NewSessionWorkflow(launch: .run(target))
    var selection = form.selection
    let start = form.workflowStart(text: "", selection: &selection)
    #expect(selection.workflowId == target.id)
    #expect(start.message.contains("run the saved workflow"))
    #expect(form.workflow?.plannerDraft == nil)
  }
}
