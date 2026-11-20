import OmnigentPlatform
import SwiftUI

/// Settings › Omni Advisor: the caller's switch, as the web's General › Omni Advisor group.
struct AdvisorSettingsPane: View {
  let state: AdvisorViewState?
  let actions: AdvisorActions

  var body: some View {
    Section {
      switch state?.settings ?? .loading {
      case .loading:
        LoadingCaption(title: "Loading\u{2026}").controlSize(.small)
      case .failed:
        AdvisorLoadFailure(
          message: "Couldn\u{2019}t load Omni Advisor settings.", retry: actions.retry)
      case .ready(let switches):
        Toggle(
          isOn: Binding(
            get: { switches.userOn }, set: { actions.setEnabled?(.user, $0) })
        ) {
          Text("Omni Advisor")
          Text(
            switches.workspaceEnabled
              ? "Omni Advisor reads your recent sessions on a schedule and posts follow-ups, related information, and reminders to your Inbox."
              : "An admin turned Omni Advisor off for this workspace.")
        }
        .disabled(
          !switches.workspaceEnabled || state?.isSavingSwitch == true
            || actions.setEnabled == nil
        )
        .accessibilityIdentifier("settings.advisor-switch")
        .settingsSearchAnchor("settings.advisor-switch")
      }
      if let error = state?.switchError {
        Text(error).font(.callout).foregroundStyle(Theme.failure)
      }
    }
  }
}

/// Admin › General's Omni Advisor groups: the workspace switch, the prompt every user's runs
/// follow, and Run now, as the web's `ProactiveAgentAdminControls`.
struct AdvisorAdminSections: View {
  let state: AdvisorViewState
  let actions: AdvisorActions
  @State private var draft: String?
  @State private var users = ""

  var body: some View {
    Section("Omni Advisor") {
      switch state.settings {
      case .loading:
        LoadingCaption(title: "Loading\u{2026}").controlSize(.small)
      case .failed:
        AdvisorLoadFailure(
          message: "Couldn\u{2019}t load Omni Advisor settings.", retry: actions.retry)
      case .ready(let switches):
        Toggle(
          isOn: Binding(
            get: { switches.workspaceEnabled }, set: { actions.setEnabled?(.workspace, $0) })
        ) {
          Text("Omni Advisor")
          Text(
            "Let Omni Advisor post follow-ups, related information, and reminders to each user\u{2019}s Inbox. Users can turn it off for themselves."
          )
        }
        .disabled(state.isSavingSwitch || actions.setEnabled == nil)
        .accessibilityIdentifier("settings.advisor-workspace-switch")
      }
      if let error = state.switchError {
        Text(error).font(.callout).foregroundStyle(Theme.failure)
      }
    }
    promptSection
    runSection
  }

  private var promptSection: some View {
    Section {
      switch state.prompt ?? .loading {
      case .loading:
        LoadingCaption(title: "Loading\u{2026}").controlSize(.small)
      case .failed(let message):
        AdvisorLoadFailure(message: message, retry: actions.retryPrompt)
      case .ready(let prompt, let overridden):
        TextEditor(text: Binding(get: { draft ?? prompt }, set: { draft = $0 }))
          .font(.system(.callout, design: .monospaced))
          .frame(minHeight: 180, maxHeight: 420)
          .scrollContentBackground(.hidden)
          .disabled(state.isSavingPrompt)
          .accessibilityLabel("Prompt")
          .accessibilityIdentifier("settings.advisor-prompt")
        let caption = Text(overridden ? "Using a custom prompt" : "Using the built-in prompt")
        #if os(macOS)
          HStack {
            caption.font(.callout).foregroundStyle(.secondary)
            Spacer()
            restoreButton(overridden: overridden)
            saveButton(prompt: prompt)
          }
        #else
          // A row's buttons all fire on a tap in an iOS form, so each action gets its own row.
          caption.font(.callout).foregroundStyle(.secondary)
          saveButton(prompt: prompt)
          restoreButton(overridden: overridden)
        #endif
      }
      if let error = state.promptError {
        Text(error).font(.callout).foregroundStyle(Theme.failure)
      }
    } header: {
      Text("Prompt")
    } footer: {
      Text(
        "Replaces Omni Advisor\u{2019}s built-in instructions for every user, starting with the next run. Restoring the default follows the built-in prompt again as releases update it."
      )
    }
  }

  private var runSection: some View {
    Section {
      #if os(macOS)
        HStack {
          usersField
          runButton
        }
      #else
        usersField
        runButton
      #endif
      if let summary = state.runSummary {
        Text(summary).font(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("settings.advisor-run-summary")
      }
      if let error = state.runError {
        Text(error).font(.callout).foregroundStyle(Theme.failure)
      }
    } header: {
      Text("Run now")
    } footer: {
      Text(
        "Start runs right away for these users, separated by commas or spaces, or * for everyone who has Omni Advisor on. Users who have not started a session since it was enabled have no run to start yet."
      )
    }
  }

  private func restoreButton(overridden: Bool) -> some View {
    Button("Restore Default") { save(nil) }
      .disabled(state.isSavingPrompt || !overridden || actions.savePrompt == nil)
      .accessibilityIdentifier("settings.advisor-prompt-restore")
  }

  private func saveButton(prompt: String) -> some View {
    Button("Save Prompt") { save(draft) }
      .disabled(!canSave(prompt))
      .accessibilityIdentifier("settings.advisor-prompt-save")
  }

  private var usersField: some View {
    TextField("Users", text: $users, prompt: Text("alice@example.com, bob@example.com or *"))
      .labelsHidden()
      .accessibilityLabel("Users to run for")
      .accessibilityIdentifier("settings.advisor-run-users")
      #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.emailAddress)
      #endif
  }

  private var runButton: some View {
    Button("Run Now") { actions.run?(users) }
      .disabled(state.isRunning || Self.isBlank(users) || actions.run == nil)
      .accessibilityIdentifier("settings.advisor-run")
  }

  private func canSave(_ prompt: String) -> Bool {
    guard let draft, actions.savePrompt != nil, !state.isSavingPrompt else { return false }
    return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft != prompt
  }

  private func save(_ text: String?) {
    guard let savePrompt = actions.savePrompt else { return }
    Task {
      // The prompt now in use replaces the draft; a failure keeps the draft.
      if let saved = await savePrompt(text) { draft = saved }
    }
  }

  /// Nothing but commas and white space: no user to run for.
  static func isBlank(_ users: String) -> Bool {
    users.split(whereSeparator: { $0 == "," || $0.isWhitespace }).isEmpty
  }
}

/// A failed read, with its Retry.
private struct AdvisorLoadFailure: View {
  let message: String
  let retry: (@MainActor () -> Void)?

  var body: some View {
    HStack {
      Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.failure)
      Spacer()
      if let retry { Button("Retry", action: retry) }
    }
    .font(.callout)
  }
}
