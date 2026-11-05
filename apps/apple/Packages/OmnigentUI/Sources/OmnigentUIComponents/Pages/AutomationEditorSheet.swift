public import SwiftUI

/// Creates or edits an automation, in the web dialog's order: name, session, prompt or trigger,
/// schedule, where it runs (host or sandbox, folder, project), the agent and its model, effort
/// and permission mode.
public struct AutomationEditorSheet: View {
  @Binding private var draft: AutomationDraftState
  private let context: AutomationEditorContext
  private let save: @MainActor () -> Void
  private let cancel: @MainActor () -> Void

  /// Creates the sheet.
  /// - Parameters:
  ///   - draft: The fields.
  ///   - context: What the editor offers, server support and the save state.
  ///   - save: Save the fields.
  ///   - cancel: Close without saving.
  public init(
    draft: Binding<AutomationDraftState>, context: AutomationEditorContext,
    save: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void
  ) {
    _draft = draft
    self.context = context
    self.save = save
    self.cancel = cancel
  }

  /// The form.
  public var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Name", text: $draft.name, prompt: Text("daily-brief"))
            .accessibilityIdentifier("automation-name")
          if context.supportsSessionModes { sessionMode }
        }
        promptFields
        Section("Schedule") { schedule }
        Section("Runs on") { placement }
        Section("Harness") { harness }
        if let overrides = context.overrides { advanced(overrides) }
        if let message = context.error ?? context.blocker {
          Section {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
              .accessibilityIdentifier("automation-error")
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button(context.isEditing ? "Save changes" : "Create automation", action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!canSave)
          .accessibilityIdentifier("automation-save")
      }
      .padding(Theme.Spacing.large)
    }
    .frame(minWidth: 520, idealWidth: 580, minHeight: 600, idealHeight: 720)
    .navigationTitle(context.isEditing ? "Edit automation" : "New automation")
  }

  private var canSave: Bool {
    draft.canSave && !context.isSaving && context.blocker == nil && context.scheduleProblem == nil
      && (draft.trigger == nil || !context.triggerPrompt.isEmpty)
  }

  @ViewBuilder private var sessionMode: some View {
    Picker("Session", selection: $draft.continuesSession) {
      Text("New session each run").tag(false)
      Text("Continue in the same session").tag(true)
    }
    .disabled(draft.trigger != nil)
    .accessibilityIdentifier("automation-session-mode")
    Text(sessionNote).font(.callout).foregroundStyle(.secondary)
    if context.isEditing, draft.continuesSession, context.hasContinuingSession {
      Toggle("Start a new session on the next run", isOn: $draft.startNewSession)
        .accessibilityIdentifier("automation-start-new-session")
    }
  }

  private var sessionNote: String {
    if draft.trigger != nil {
      return
        "Trigger automations keep one session, which remembers its last check and the sessions it already started."
    }
    return draft.continuesSession
      ? "The first run starts a session, and later runs send their prompt to it so the agent keeps its context, even while an earlier run is still working."
      : "Each run starts a new session."
  }

  @ViewBuilder private var promptFields: some View {
    if let template = context.trigger, draft.trigger != nil {
      AutomationTriggerFields(
        trigger: Binding(
          get: { draft.trigger ?? AutomationTriggerDraft(source: "", event: "") },
          set: { draft.trigger = $0 }),
        template: template, renderedPrompt: context.triggerPrompt,
        editAsPrompt: {
          draft.prompt = context.triggerPrompt
          draft.trigger = nil
        })
    } else {
      Section("Prompt") {
        TextField(
          "Prompt", text: $draft.prompt, prompt: Text("What should the agent do each run?"),
          axis: .vertical
        )
        .lineLimit(4...10)
        .labelsHidden()
        .accessibilityIdentifier("automation-prompt")
      }
    }
  }

  @ViewBuilder private var schedule: some View {
    if let kept = draft.keptRule, draft.schedule == nil {
      LabeledContent("Repeats", value: kept)
      Text(
        "This schedule can\u{2019}t be edited in this form yet. Choose a frequency to replace it."
      )
      .font(.callout).foregroundStyle(.secondary)
      Button("Choose a new schedule") { draft.schedule = ScheduleChoice() }
    } else {
      ScheduleFields(choice: scheduleBinding, anchoredScheduling: context.anchoredScheduling)
      Text(context.describe(scheduleBinding.wrappedValue))
        .font(.callout).foregroundStyle(.secondary)
        .accessibilityIdentifier("automation-schedule-summary")
      if let problem = context.scheduleProblem {
        Text(problem).font(.callout).foregroundStyle(.red)
          .accessibilityIdentifier("automation-schedule-problem")
      }
    }
  }

  private var scheduleBinding: Binding<ScheduleChoice> {
    Binding(
      get: { draft.schedule ?? ScheduleChoice() },
      set: { draft.schedule = $0 })
  }

  /// The sandbox option's tag in the host picker.
  private static let sandboxTag = "\u{0}sandbox"

  @ViewBuilder private var placement: some View {
    Picker("Host", selection: hostSelection) {
      if draft.hostID.isEmpty, !draft.runsInSandbox {
        Text(context.isEditing ? "Most recently active host" : "Pick a host").tag("")
      }
      if let sandbox = context.sandboxLabel ?? (draft.runsInSandbox ? "New Sandbox" : nil) {
        Text(sandbox).tag(Self.sandboxTag)
      }
      ForEach(context.hosts) { Text($0.name).tag($0.id) }
      if !draft.hostID.isEmpty, !context.hosts.contains(where: { $0.id == draft.hostID }) {
        Text(draft.hostID).tag(draft.hostID)
      }
    }
    .accessibilityIdentifier("automation-host")
    Text(hostNote).font(.callout).foregroundStyle(.secondary)
    if !draft.runsInSandbox, !draft.hostID.isEmpty {
      TextField("Workspace", text: $draft.workspace, prompt: Text("Home folder"))
        .accessibilityIdentifier("automation-workspace")
      Text("Defaults to the host\u{2019}s home directory. Enter an absolute path to pin a folder.")
        .font(.callout).foregroundStyle(.secondary)
    }
    if context.supportsProjects {
      Picker("Project", selection: $draft.projectID) {
        Text("No project").tag("")
        ForEach(context.projects) { Text($0.name).tag($0.id) }
        if !draft.projectID.isEmpty,
          !context.projects.contains(where: { $0.id == draft.projectID })
        {
          Text("Project unavailable").tag(draft.projectID)
        }
      }
      .accessibilityIdentifier("automation-project")
    }
  }

  private var hostSelection: Binding<String> {
    Binding(
      get: { draft.runsInSandbox ? Self.sandboxTag : draft.hostID },
      set: { tag in
        if tag == Self.sandboxTag {
          draft.runsInSandbox = true
          draft.hostID = ""
          draft.workspace = ""
        } else {
          draft.runsInSandbox = false
          draft.hostID = tag
        }
      })
  }

  private var hostNote: String {
    if draft.runsInSandbox {
      return draft.continuesSession
        ? "Keeps one sandbox for every run, including a session started after a reset. Shutdown follows the server\u{2019}s sandbox configuration."
        : "Provisions a fresh sandbox for each run. Shutdown follows the server\u{2019}s sandbox configuration."
    }
    if draft.hostID.isEmpty {
      return context.isEditing
        ? "Runs on the connected host you used most recently. Pick a host to pin it."
        : "Pick the host this automation runs on."
    }
    return "Runs on this host. A run fails while the host is offline."
  }

  @ViewBuilder private var harness: some View {
    Picker("Agent", selection: $draft.agentID) {
      if draft.agentID.isEmpty { Text("Choose an agent").tag("") }
      ForEach(context.agents) { Text($0.name).tag($0.id) }
      if !draft.agentID.isEmpty, !context.agents.contains(where: { $0.id == draft.agentID }) {
        Text(draft.agentID).tag(draft.agentID)
      }
    }
    .accessibilityIdentifier("automation-agent")
    if let note = context.agentNote {
      Text(note).font(.callout).foregroundStyle(.secondary)
    }
    if context.overrides == nil {
      Text("Uses this agent\u{2019}s default model, effort, and permission settings")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private func advanced(_ options: AutomationOverrideOptions) -> some View {
    Section("Advanced") {
      overridePicker("Model", selection: $draft.model, options: options.models)
        .accessibilityIdentifier("automation-model")
      overridePicker("Effort", selection: $draft.effort, options: options.efforts)
        .accessibilityIdentifier("automation-effort")
      overridePicker(
        "Permission mode", selection: $draft.permissionMode, options: options.permissionModes
      )
      .accessibilityIdentifier("automation-permission-mode")
      Text(
        "Leave on Default to use the agent\u{2019}s configured model, effort, and permission mode. Automations run unattended, so a prompting mode (Manual or Plan) will wait for approval that never comes."
      )
      .font(.callout).foregroundStyle(.secondary)
    }
  }

  private func overridePicker(
    _ title: String, selection: Binding<String>, options: [AutomationOption]
  ) -> some View {
    Picker(title, selection: selection) {
      Text("Default").tag("")
      ForEach(options) { Text($0.name).tag($0.id) }
      if !selection.wrappedValue.isEmpty,
        !options.contains(where: { $0.id == selection.wrappedValue })
      {
        Text(selection.wrappedValue).tag(selection.wrappedValue)
      }
    }
  }
}
