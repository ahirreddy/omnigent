import SwiftUI

/// New automation's Workflow field (the web's `WorkflowField`): one of the caller's saved
/// workflows for each run to follow, or none. An automation made from a workflow shows it fixed.
struct AutomationWorkflowField: View {
  @Binding var draft: AutomationDraftState
  /// The saved workflows to choose from.
  let workflows: [AutomationOption]

  var body: some View {
    Section {
      if draft.workflowLocked, let workflow = draft.workflow {
        LabeledContent("Workflow") {
          Label(workflow.name, systemImage: "flowchart")
        }
        .accessibilityIdentifier("automation-workflow")
      } else {
        Picker("Workflow", selection: choice) {
          Text("No workflow").tag(String?.none)
          ForEach(options) { workflow in
            Label(workflow.name, systemImage: "flowchart").tag(Optional(workflow.id))
          }
        }
        .accessibilityIdentifier("automation-workflow")
      }
    } footer: {
      if draft.workflow != nil, !draft.showsInstructions {
        Text("Each run follows this workflow as saved.")
          .accessibilityIdentifier("automation-workflow-note")
      }
    }
  }

  /// The list, with the chosen workflow kept when it isn't in the page read.
  private var options: [AutomationOption] {
    guard let chosen = draft.workflow, !workflows.contains(where: { $0.id == chosen.id }) else {
      return workflows
    }
    return [chosen] + workflows
  }

  private var choice: Binding<String?> {
    Binding(
      get: { draft.workflow?.id },
      set: { id in draft.workflow = id.flatMap { id in options.first { $0.id == id } } })
  }
}

extension AutomationEditorSheet {
  /// The Workflow field shows where the server runs workflows and the caller has saved some,
  /// or one is already chosen.
  var showsWorkflowField: Bool {
    context.offersWorkflows && (!context.workflows.isEmpty || draft.workflow != nil)
  }

  var workflowField: AutomationWorkflowField {
    AutomationWorkflowField(draft: $draft, workflows: context.workflows)
  }
}
