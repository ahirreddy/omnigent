import SwiftUI

/// What a trigger's worker fields say, as the web's `TriggerWorkerSettingsFields`.
enum AutomationWorkerText {
  /// A new trigger's note on what the fields above run.
  static let pollingIntro =
    "The agent, model, effort, and permissions above run the polling session, which checks for new matches. A lighter model keeps frequent checks cheaper."
  /// The "" permission when matching sessions follow the polling session's mode.
  static let inheritedPermission = "Same as polling session"

  /// The group's name: one task session takes every match, else a session each.
  static func groupName(taskSession: Bool) -> String {
    taskSession ? "Task session" : "Matching sessions"
  }

  /// An edited trigger's note on the polling session's own settings.
  static func pollingNote(reusesSession: Bool) -> String {
    reusesSession
      ? "The current polling session keeps these. Check Start a new session on the next run to change them."
      : "The next run starts a new polling session with these."
  }

  /// The note under the fields: who takes them, and what Default and the modes mean.
  static func footer(
    creating: Bool, taskSession: Bool, followsPolling: Bool, inheritsPolling: Bool,
    offersModes: Bool
  ) -> String {
    var text: String
    switch (creating, taskSession) {
    case (true, true): text = "The task session started for the first match uses these. "
    case (true, false): text = "Each session started for a matching item uses these. "
    case (false, true):
      text =
        "Applies to the next task session. The current task session and the polling session keep their settings; archive the task session so the next match starts one with these. "
    case (false, false):
      text =
        "Applies to new sessions started for matching items. Existing sessions, including the polling session, keep their settings. "
    }
    if followsPolling { text += "They match the polling session until you change them. " }
    text += "Default uses the selected harness\u{2019}s configuration."
    if inheritsPolling {
      text += " Pick another mode so they don\u{2019}t run in the polling session\u{2019}s."
    }
    if offersModes { text += " Modes that skip approval aren\u{2019}t available here." }
    return text
  }

  /// Why a saved mode stops matching sessions from starting.
  static func unapplied(_ mode: String, modesApply: Bool) -> String {
    let reason =
      modesApply
      ? "which this harness doesn\u{2019}t offer here" : "which this server can\u{2019}t apply"
    return "Matching sessions are set to start in \(mode), \(reason), so they won\u{2019}t start."
  }
}

/// A trigger's worker fields under Advanced settings: the model, effort and permissions its
/// matching sessions start with, and on an edit their harness.
extension AutomationEditorSheet {
  /// The rows, or none when the trigger's harness takes no settings.
  var workerRows: [AdvancedRow] {
    guard let trigger = draft.trigger, let options = context.workerOptions,
      let shown = trigger.worker ?? context.workerDefaults
    else { return [] }
    let creating = !context.isEditing
    var rows: [AdvancedRow] = []
    if !creating {
      let reuses = draft.continuesSession && context.hasContinuingSession && !draft.startNewSession
      rows.append(
        AdvancedRow(
          "polling", nil,
          groupHeading("Polling session", AutomationWorkerText.pollingNote(reusesSession: reuses))))
    }
    rows.append(
      AdvancedRow(
        "worker", nil,
        groupHeading(
          AutomationWorkerText.groupName(taskSession: trigger.taskSession),
          creating ? AutomationWorkerText.pollingIntro : nil)))
    if !creating {
      rows.append(AdvancedRow("worker-agent", "Harness for matching sessions", workerAgentPicker))
    }
    if options.takesModel || !options.models.isEmpty || !shown.model.isEmpty {
      rows.append(
        AdvancedRow(
          "worker-model", "Model",
          overridePicker("Model", selection: workerBinding(\.model), options: options.models)))
    }
    if !options.efforts.isEmpty || !shown.effort.isEmpty {
      rows.append(
        AdvancedRow(
          "worker-effort", "Effort",
          overridePicker("Effort", selection: workerBinding(\.effort), options: options.efforts)))
    }
    if !options.permissionModes.isEmpty || !shown.permissionMode.isEmpty {
      rows.append(AdvancedRow("worker-permission", "Permissions", workerPermissionPicker(options)))
    }
    if !shown.permissionMode.isEmpty,
      !options.permissionModes.contains(where: { $0.id == shown.permissionMode })
    {
      rows.append(AdvancedRow("worker-unapplied", nil, unappliedMode(shown.permissionMode)))
    }
    let footer = AutomationWorkerText.footer(
      creating: creating, taskSession: trigger.taskSession,
      followsPolling: creating && trigger.worker == nil,
      inheritsPolling: context.workerInheritsPolling,
      offersModes: !options.permissionModes.isEmpty)
    rows.append(
      AdvancedRow(
        "worker-footer", nil,
        Text(footer).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)))
    return rows
  }

  private func groupHeading(_ title: String, _ note: String?) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      Text(title).font(.headline)
      if let note {
        Text(note).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// A field of the workers; the first change on a new trigger stops it following the polling
  /// session.
  private func workerBinding(_ field: WritableKeyPath<AutomationTriggerWorker, String>)
    -> Binding<String>
  {
    Binding(
      get: { (draft.trigger?.worker ?? context.workerDefaults)?[keyPath: field] ?? "" },
      set: { value in
        guard var worker = draft.trigger?.worker ?? context.workerDefaults else { return }
        worker[keyPath: field] = value
        if field == \.model,
          !(context.workerOptions?.efforts ?? []).contains(where: { $0.id == worker.effort })
        {
          worker.effort = ""
        }
        draft.trigger?.worker = worker
      })
  }

  private func workerPermissionPicker(_ options: AutomationOverrideOptions) -> some View {
    let selection = workerBinding(\.permissionMode)
    return Picker("Permissions", selection: selection) {
      Text(context.workerInheritsPolling ? AutomationWorkerText.inheritedPermission : "Default")
        .tag("")
      ForEach(options.permissionModes) { Text($0.name).tag($0.id) }
      if !selection.wrappedValue.isEmpty,
        !options.permissionModes.contains(where: { $0.id == selection.wrappedValue })
      {
        Text(selection.wrappedValue).tag(selection.wrappedValue)
      }
    }
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier("automation-worker-permission")
  }

  /// An edit's harness for its matching sessions; a switch drops their other settings.
  private var workerAgentPicker: some View {
    let agent = Binding(
      get: { draft.trigger?.worker?.agentID ?? draft.agentID },
      set: { id in
        guard var worker = draft.trigger?.worker else { return }
        worker.agentID = id
        worker.model = ""
        worker.effort = ""
        worker.permissionMode = ""
        draft.trigger?.worker = worker
      })
    return Picker("Harness for matching sessions", selection: agent) {
      ForEach(context.agents) { Text($0.name).tag($0.id) }
    }
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier("automation-worker-agent")
  }

  private func unappliedMode(_ mode: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(AutomationWorkerText.unapplied(mode, modesApply: context.workerModesApply))
        .font(.callout)
        .foregroundStyle(Theme.failure)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Clear") { draft.trigger?.worker?.permissionMode = "" }
        .accessibilityIdentifier("automation-worker-permission-clear")
    }
  }
}
