import SwiftUI

/// The controls both layouts place.
extension AutomationEditorSheet {
  /// The sandbox option's tag in the host picker.
  static let sandboxTag = "\u{0}sandbox"

  var nameField: some View {
    TextField("Name", text: $draft.name, prompt: Text("Name your automation"))
      .accessibilityIdentifier("automation-name")
  }

  /// Schedule or an integration, as the web's Trigger type; only a new automation switches.
  var triggerTypePicker: some View {
    Picker("Trigger type", selection: triggerTypeSelection) {
      Label("Schedule", systemImage: "clock").tag("schedule")
      ForEach(context.triggerTypes) { type in
        Label(type.name, systemImage: AutomationTemplateCard.symbol(forSource: type.id))
          .tag(type.id)
      }
      // A template opened where the types aren't listed still names its own.
      if let source = draft.trigger?.source,
        !context.triggerTypes.contains(where: { $0.id == source })
      {
        Label(
          context.trigger?.serviceName.isEmpty == false
            ? context.trigger?.serviceName ?? source : source,
          systemImage: AutomationTemplateCard.symbol(forSource: source)
        )
        .tag(source)
      }
    }
    .disabled(context.switchTriggerType == nil || context.isSaving)
    .help("Trigger type")
    .accessibilityIdentifier("automation-trigger-type")
  }

  private var triggerTypeSelection: Binding<String> {
    Binding(
      get: { draft.trigger?.source ?? "schedule" },
      set: { id in
        guard id != (draft.trigger?.source ?? "schedule") else { return }
        context.switchTriggerType?(id == "schedule" ? nil : id)
      })
  }

  /// The schedule's frequency and time, or the rule kept as it is until a new one is chosen.
  var scheduleRows: some View {
    AutomationScheduleRows(draft: $draft, context: context)
  }

  @ViewBuilder var scheduleProblem: some View {
    if let problem = context.scheduleProblem {
      Text(problem).font(.callout).foregroundStyle(Theme.failure)
        .accessibilityIdentifier("automation-schedule-problem")
    }
  }

  /// A saved trigger's schedule that doesn't fit where it runs now, with its replacement.
  @ViewBuilder var triggerScheduleReplacement: some View {
    if isTrigger, context.triggerScheduleUnsupported {
      HStack(spacing: Theme.Spacing.medium) {
        Text(
          "This automation\u{2019}s saved schedule isn\u{2019}t supported by the current run setup."
        )
        .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        if let replace = context.useSupportedTriggerSchedule {
          Button("Use supported schedule", action: replace)
            .controlSize(.small)
            .accessibilityIdentifier("automation-trigger-schedule-replacement")
        }
      }
      .font(.callout)
    }
  }

  /// Where it runs: a host, or a new sandbox each run.
  var hostPicker: some View {
    Picker("Run on", selection: hostSelection) {
      if draft.hostID.isEmpty, !draft.runsInSandbox {
        Text(context.isEditing ? "Most recently active host" : "Pick a host").tag("")
      }
      if let sandbox = context.sandboxLabel ?? (draft.runsInSandbox ? "New Sandbox" : nil) {
        Label(sandbox, systemImage: "shippingbox").tag(Self.sandboxTag)
      }
      ForEach(context.hosts) { Label($0.name, systemImage: "desktopcomputer").tag($0.id) }
      if !draft.hostID.isEmpty, !context.hosts.contains(where: { $0.id == draft.hostID }) {
        Text(draft.hostID).tag(draft.hostID)
      }
    }
    .help("Run on")
    .accessibilityIdentifier("automation-host")
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

  var agentPicker: some View {
    Picker("Agent", selection: $draft.agentID) {
      if draft.agentID.isEmpty { Text("Choose an agent").tag("") }
      ForEach(context.agents) { Text($0.name).tag($0.id) }
      if !draft.agentID.isEmpty, !context.agents.contains(where: { $0.id == draft.agentID }) {
        Text(draft.agentID).tag(draft.agentID)
      }
    }
    .help("Agent")
    .accessibilityIdentifier("automation-agent")
  }

  /// The harness offers permission modes, or one is saved.
  var offersPermissions: Bool {
    guard let options = context.overrides else { return false }
    return !options.permissionModes.isEmpty || !draft.permissionMode.isEmpty
  }

  /// The harness's permission modes; shown where ``offersPermissions``.
  var permissionPicker: some View {
    let modes = context.overrides?.permissionModes ?? []
    return Picker("Permissions", selection: $draft.permissionMode) {
      Text("Default permissions").tag("")
      ForEach(modes) { Text($0.name).tag($0.id) }
      if !draft.permissionMode.isEmpty, !modes.contains(where: { $0.id == draft.permissionMode }) {
        Text(draft.permissionMode).tag(draft.permissionMode)
      }
    }
    .help("Permissions")
    .accessibilityIdentifier("automation-permission-mode")
  }

  /// What a pick under Run on, Agent or Permissions means, and what blocks Save there.
  @ViewBuilder var runNotes: some View {
    if let blocker = context.blocker {
      Label(blocker, systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(Theme.failure)
        .accessibilityIdentifier("automation-blocker")
    }
    if let note = hostNote {
      Text(note).font(.callout).foregroundStyle(.secondary)
    }
    if let note = context.agentNote {
      Text(note).font(.callout).foregroundStyle(.secondary)
    }
  }

  /// Said about where it runs, only where it changes what a run does.
  private var hostNote: String? {
    if draft.runsInSandbox {
      return draft.continuesSession
        ? "Keeps one sandbox for every run, including a session started after a reset. Shutdown follows the server\u{2019}s sandbox configuration."
        : "Provisions a fresh sandbox for each run. Shutdown follows the server\u{2019}s sandbox configuration."
    }
    if draft.hostID.isEmpty, context.isEditing {
      return "Runs on the connected host you used most recently. Pick a host to pin it."
    }
    if context.hosts.first(where: { $0.id == draft.hostID })?.name.hasSuffix("(offline)") == true {
      return "This host is offline. Runs fail until it reconnects."
    }
    return nil
  }

  /// One row under Advanced settings: a label and its control, or, without a label, form rows
  /// of their own (an edit's schedule).
  struct AdvancedRow: Identifiable {
    let id: String
    let label: String?
    let control: AnyView

    init(_ id: String, _ label: String?, _ control: some View) {
      self.id = id
      self.label = label
      self.control = AnyView(control)
    }

    /// The row in a form.
    @ViewBuilder var formRow: some View {
      if let label {
        LabeledContent(label) { control }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("automation-advanced-\(id)")
      } else {
        control
      }
    }
  }

  /// The rows under Advanced settings, in the web's order.
  func advancedRows() -> [AdvancedRow] {
    var rows = overrideRows
    if context.supportsSessionModes, !isTrigger, draft.sourceSessionID == nil {
      rows.append(AdvancedRow("session", "Session continuity", sessionPicker))
    }
    if draft.trigger != nil, !context.isEditing {
      rows.append(AdvancedRow("task-session", "Session continuity", taskSessionPicker))
    }
    if context.isEditing, draft.continuesSession, context.hasContinuingSession {
      rows.append(AdvancedRow("reset", "Start a new session on the next run", resetToggle))
    }
    if !context.mcpServices.isEmpty {
      rows.append(AdvancedRow("mcp", "MCP services", mcpMenu))
    }
    if scheduleInAdvanced {
      rows.append(AdvancedRow("schedule", nil, scheduleRows))
    }
    if !isTrigger, draft.schedule != nil {
      rows.append(
        AdvancedRow(
          "ends", "Ends",
          ScheduleEndFields(
            choice: scheduleBinding, anchoredScheduling: context.anchoredScheduling, inline: true)
        ))
    }
    if !draft.runsInSandbox {
      rows.append(AdvancedRow("workspace", "Workspace", workspaceField))
    }
    if context.supportsProjects {
      rows.append(AdvancedRow("project", "Project", projectPicker))
    }
    rows.append(AdvancedRow("cost", "Cost limit per run (USD)", costField))
    return rows
  }

  /// The model and effort, which the web picks beside the agent.
  private var overrideRows: [AdvancedRow] {
    guard let options = context.overrides else { return [] }
    var rows: [AdvancedRow] = []
    if options.takesModel || !options.models.isEmpty || !draft.model.isEmpty {
      rows.append(
        AdvancedRow(
          "model", "Model",
          overridePicker("Model", selection: $draft.model, options: options.models)
            .accessibilityIdentifier("automation-model")))
    }
    if !options.efforts.isEmpty || !draft.effort.isEmpty {
      rows.append(
        AdvancedRow(
          "effort", "Effort",
          overridePicker("Effort", selection: $draft.effort, options: options.efforts)
            .accessibilityIdentifier("automation-effort")))
    }
    return rows
  }

  private var sessionPicker: some View {
    Picker("Session continuity", selection: newForWorkflow($draft.continuesSession)) {
      Text("New session each run").tag(false)
      Text("Continue one session").tag(true)
    }
    .labelsHidden()
    .fixedSize()
    .disabled(context.workflowNeedsNewSessions)
    .accessibilityIdentifier("automation-session-mode")
  }

  private var taskSessionPicker: some View {
    let shared = Binding(
      get: { draft.trigger?.taskSession ?? false }, set: { draft.trigger?.taskSession = $0 })
    return Picker("Session continuity", selection: newForWorkflow(shared)) {
      Text("New session for each match").tag(false)
      Text("One task session for all matches").tag(true)
    }
    .labelsHidden()
    .fixedSize()
    .disabled(context.workflowNeedsNewSessions)
    .accessibilityIdentifier("automation-trigger-session-mode")
  }

  /// Each run of a workflow needs its own session, so the choice shows a new one, fixed.
  private func newForWorkflow(_ shared: Binding<Bool>) -> Binding<Bool> {
    Binding(
      get: { shared.wrappedValue && !context.workflowNeedsNewSessions },
      set: { shared.wrappedValue = $0 })
  }

  private var resetToggle: some View {
    Toggle("Start a new session on the next run", isOn: $draft.startNewSession)
      .labelsHidden()
      #if os(macOS)
        .toggleStyle(.checkbox)
      #endif
      .accessibilityIdentifier("automation-start-new-session")
  }

  /// The MCP services every run starts with, picked in a menu, as the web's MCP popover.
  private var mcpMenu: some View {
    Menu {
      Section("Every run starts with these. Runs are unattended, so sign in to each one now.") {
        ForEach(context.mcpServices) { service in
          Toggle(
            isOn: Binding(
              get: { draft.mcpServices.contains(service.id) },
              set: { isOn in
                draft.mcpServices.removeAll { $0 == service.id }
                if isOn { draft.mcpServices.append(service.id) }
              })
          ) {
            Text(service.title)
            if !service.isConnected { Text("Not signed in") }
          }
          .accessibilityIdentifier("automation-mcp-\(service.id)")
        }
      }
    } label: {
      Label(mcpSummary, systemImage: "powerplug")
    }
    .fixedSize()
    .accessibilityIdentifier("automation-mcp-services")
  }

  private var mcpSummary: String {
    let offered = draft.mcpServices.filter { id in context.mcpServices.contains { $0.id == id } }
    return offered.isEmpty ? "No MCPs" : "MCPs \u{00B7} \(offered.count)"
  }

  /// A folder on the pinned host; empty is its home directory.
  private var workspaceField: some View {
    TextField("Workspace", text: $draft.workspace, prompt: Text("No workspace"))
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .frame(maxWidth: 280)
      .disabled(draft.hostID.isEmpty && draft.workspace.isEmpty)
      .help("An absolute path on the host. Empty runs in the host\u{2019}s home directory.")
      .accessibilityIdentifier("automation-workspace")
  }

  private var projectPicker: some View {
    Picker("Project", selection: $draft.projectID) {
      Text("No project").tag("")
      ForEach(context.projects) { Text($0.name).tag($0.id) }
      if !draft.projectID.isEmpty, !context.projects.contains(where: { $0.id == draft.projectID }) {
        Text("Project unavailable").tag(draft.projectID)
      }
    }
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier("automation-project")
  }

  static let costHelp =
    "Each run gets a fresh budget, including when continuing an existing session: its recorded spend at the start of the run plus this amount. Reaching that threshold blocks further model requests and tool calls, but an in-progress response can overshoot it. Leave blank for no automation cost limit. Changes apply to future runs."

  private var costField: some View {
    TextField("Cost limit per run (USD)", text: $draft.maxCost, prompt: Text("No limit"))
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .frame(width: 128)
      .help(Self.costHelp)
      .accessibilityHint(Self.costHelp)
      .accessibilityIdentifier("automation-cost-limit")
  }

  /// What the Advanced settings say: why one can't be saved, and what a choice means.
  @ViewBuilder var advancedNotes: some View {
    if let problem = context.costLimitProblem {
      Text(problem).font(.callout).foregroundStyle(Theme.failure)
        .accessibilityIdentifier("automation-cost-limit-problem")
    }
    if let message = context.overrides?.catalogMessage {
      Text(message).font(.callout).foregroundStyle(.secondary)
    }
    if let problem = context.mcpProblem {
      Text(problem).font(.callout).foregroundStyle(Theme.failure)
    }
    if scheduleInAdvanced { scheduleProblem }
  }

  func overridePicker(
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
    .labelsHidden()
    .fixedSize()
  }
}
