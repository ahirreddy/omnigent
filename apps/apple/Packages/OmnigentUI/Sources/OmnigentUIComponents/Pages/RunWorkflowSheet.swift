import SwiftUI

/// Run a workflow (web `WorkflowPicker` and `WorkflowDialog`): pick one of the saved workflows,
/// or describe a new one; then the run's details or the description, and whether to review the
/// plan before work starts. Without saved workflows it opens on the description.
struct RunWorkflowSheet: View {
  let source: WorkflowRunSource
  let close: @MainActor () -> Void
  @State private var search = ""
  @State private var picked: WorkflowRowState?
  @State private var describing = false
  @State private var text = ""
  @State private var reviewPlanFirst = true
  @FocusState private var textFocused: Bool

  var body: some View {
    let choices = source.choices(search)
    Group {
      if picked == nil, !describing, choices.hasAny || choices.hasMore || !search.isEmpty {
        picker(choices)
      } else {
        form
      }
    }
    .onAppear {
      source.refresh()
      text = source.draft()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("run-workflow-sheet")
  }

  /// The saved workflows by name, with New workflow under them.
  private func picker(_ choices: RunWorkflowChoices) -> some View {
    WorkflowSheetChrome(
      title: "Run a workflow", actionTitle: "New workflow", canSubmit: true,
      submit: describeNew, cancel: close, actionIdentifier: "run-workflow-describe"
    ) {
      Section {
        SearchField("Search workflows", text: $search, identifier: "run-workflow-search")
        if choices.rows.isEmpty {
          Text("No matching workflows").foregroundStyle(.secondary)
        }
        ForEach(choices.rows) { row in
          Button {
            pick(row)
          } label: {
            HStack(spacing: Theme.Spacing.small) {
              Image(systemName: "flowchart").foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(row.name).lineLimit(1)
              Text(line(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("run-workflow-pick-\(row.id)")
        }
        if choices.hasMore, let more = source.loadMore {
          Button(choices.isLoadingMore ? "Loading\u{2026}" : "Load more workflows", action: more)
            .disabled(choices.isLoadingMore)
        }
      }
    }
  }

  /// "Shared by Ada · first line of its description".
  private func line(_ row: WorkflowRowState) -> String {
    let first = row.description.split(separator: "\n").first.map(String.init) ?? ""
    return row.sharedBy.map { "Shared by \($0) \u{00B7} \(first)" } ?? first
  }

  private var form: some View {
    let blocked = source.blockedReason()
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return WorkflowSheetChrome(
      title: picked.map { "Run \($0.name)" } ?? "Run a workflow", actionTitle: "Run workflow",
      canSubmit: (picked != nil || !trimmed.isEmpty) && blocked == nil, blockedReason: blocked,
      submit: submit, cancel: close, actionIdentifier: "run-workflow-run"
    ) {
      Section {
        Text(
          picked?.description
            ?? "The agent turns your description into a plan and works through it step by step. Follow along in the Tasks tab."
        )
        .foregroundStyle(.secondary)
        .lineLimit(picked == nil ? nil : 3)
        .help(picked?.description ?? "")
        .accessibilityIdentifier("run-workflow-about")
      }
      Section(picked == nil ? "Description" : "Details") {
        TextField(
          picked == nil ? "Description" : "Details", text: $text,
          prompt: Text(
            picked == nil
              ? "Add retries to the uploader, with tests" : "Anything specific to this run"),
          axis: .vertical
        )
        .lineLimit(5...10)
        .labelsHidden()
        .focused($textFocused)
        .accessibilityIdentifier("run-workflow-text")
      }
      Section {
        Toggle("Review the plan before work starts", isOn: $reviewPlanFirst)
          .accessibilityIdentifier("run-workflow-review")
      } footer: {
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          Text("The agent shows you its plan and waits for your approval.")
          if let blocked { Text(blocked) }
        }
      }
    }
    .onAppear { textFocused = true }
  }

  /// A saved workflow runs without a review unless asked; a described one starts with it.
  private func pick(_ row: WorkflowRowState) {
    picked = row
    text = ""
    reviewPlanFirst = false
  }

  /// New workflow starts from what was typed in the search.
  private func describeNew() {
    describing = true
    if !search.trimmingCharacters(in: .whitespaces).isEmpty { text = search }
    reviewPlanFirst = true
  }

  private func submit() {
    source.run(
      RunWorkflowRequest(
        description: text.trimmingCharacters(in: .whitespacesAndNewlines),
        reviewPlanFirst: reviewPlanFirst, savedWorkflowID: picked?.id))
    close()
  }
}

/// Save as workflow (web `SaveWorkflowDialog`): the name the agent saves the session's plan
/// under, from the plan's.
struct SaveWorkflowSheet: View {
  let source: WorkflowSaveSource
  let close: @MainActor () -> Void
  @State private var name = ""
  @FocusState private var nameFocused: Bool

  var body: some View {
    let blocked = source.blockedReason()
    WorkflowSheetChrome(
      title: "Save as workflow", actionTitle: "Save workflow",
      canSubmit: !name.trimmingCharacters(in: .whitespaces).isEmpty && blocked == nil,
      blockedReason: blocked, submit: submit, cancel: close,
      actionIdentifier: "save-workflow-save"
    ) {
      Section {
        TextField("Name", text: $name, prompt: Text("Triage flaky tests"))
          .focused($nameFocused)
          .onChange(of: name) { _, text in
            if text.count > NewWorkflowSheet.nameLimit {
              name = String(text.prefix(NewWorkflowSheet.nameLimit))
            }
          }
          .accessibilityIdentifier("save-workflow-name")
      } header: {
        Text(
          "The agent saves this plan as a workflow you can run again from Run a workflow. It leaves out the details that change from run to run."
        )
        .textCase(nil)
      } footer: {
        if let blocked { Text(blocked) }
      }
    }
    .onAppear {
      name = String(source.initialName.prefix(NewWorkflowSheet.nameLimit))
      nameFocused = true
    }
    .accessibilityIdentifier("save-workflow-sheet")
  }

  private func submit() {
    source.save(name.trimmingCharacters(in: .whitespacesAndNewlines))
    close()
  }
}
