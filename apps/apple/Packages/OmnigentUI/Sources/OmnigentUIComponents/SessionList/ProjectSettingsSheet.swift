public import SwiftUI

/// A project's new-session defaults, as the web's Project settings dialog: host, working
/// directory, random worktree and base branch, agent, and the agent's model and effort. Each
/// is a starting point the new-session form fills in; "No default" stores nothing.
public struct ProjectSettingsSheet: View {
  private let state: ProjectSettingsViewState
  @Binding private var draft: ProjectSettingsDraft
  private let actions: ProjectSettingsActions

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: Choices and load state.
  ///   - draft: The fields.
  ///   - actions: Save and Cancel.
  public init(
    state: ProjectSettingsViewState, draft: Binding<ProjectSettingsDraft>,
    actions: ProjectSettingsActions
  ) {
    self.state = state
    _draft = draft
    self.actions = actions
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            "Defaults for new sessions in \(Text(state.projectName).fontWeight(.semibold)). Each is a starting point you can change per session."
          )
          .foregroundStyle(.secondary)
        }
        switch state.phase {
        case .loading:
          ProgressView().frame(maxWidth: .infinity)
        case .failed(let message):
          Label(
            "Couldn\u{2019}t load this project\u{2019}s settings: \(message). Saving is off so they aren\u{2019}t overwritten.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(Theme.failure)
          .accessibilityIdentifier("project-settings-load-error")
        case .loaded:
          fields
        }
        if let error = state.saveError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.failure)
            .textSelection(.enabled)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Project Settings")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: actions.cancel)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: actions.save)
            .disabled(state.phase != .loaded || state.isSaving)
            .accessibilityIdentifier("project-settings-save")
        }
      }
    }
    #if os(macOS)
      .frame(width: 480)
      .frame(minHeight: 320, idealHeight: 460)
    #endif
    .accessibilityIdentifier("project-settings-sheet")
  }

  @ViewBuilder private var fields: some View {
    Section {
      choicePicker("Host", selection: $draft.hostID, choices: state.hosts)
        .accessibilityIdentifier("project-settings-host")
      if state.hostTakesFolder {
        TextField("Working directory", text: $draft.workspace, prompt: Text("/path/to/repo"))
          .accessibilityIdentifier("project-settings-workspace")
      } else if draft.hostID == nil {
        LabeledContent("Working directory") {
          Text("Pick a host first").foregroundStyle(.secondary)
        }
      }
    } footer: {
      Text("Where new sessions run by default.")
    }
    Section {
      Toggle("Random worktree", isOn: $draft.useWorktree)
        .accessibilityIdentifier("project-settings-worktree")
      if draft.useWorktree {
        TextField("Base branch", text: $draft.baseBranch, prompt: Text("e.g. main"))
          .accessibilityIdentifier("project-settings-base-branch")
      }
    } footer: {
      Text(
        "Start each new session in a fresh worktree. Overrides Settings \u{203A} Git; a blank base branch uses the current branch."
      )
    }
    Section {
      choicePicker("Agent", selection: $draft.agentID, choices: state.agents)
        .accessibilityIdentifier("project-settings-agent")
      if state.showsModel {
        choicePicker("Model", selection: $draft.model, choices: state.models)
          .accessibilityIdentifier("project-settings-model")
      }
      if state.showsEffort {
        choicePicker("Effort", selection: $draft.effort, choices: state.efforts)
          .accessibilityIdentifier("project-settings-effort")
      }
    }
  }

  private func choicePicker(
    _ title: String, selection: Binding<String?>, choices: [ProjectSettingsChoice]
  ) -> some View {
    Picker(title, selection: selection) {
      Text("No default").tag(String?.none)
      ForEach(choices) { choice in
        Text(choice.title).tag(String?.some(choice.id))
      }
    }
  }
}
