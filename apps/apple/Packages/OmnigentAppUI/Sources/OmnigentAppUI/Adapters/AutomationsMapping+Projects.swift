import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The project an automation files its sessions into, chosen by name (the web's
/// `DEFAULT_AUTOMATION_PROJECT` and `resolveOrCreateProjectId`).
extension AutomationsMapping {
  /// The project a new automation files into where the server keeps projects.
  static let defaultProjectName = "Omnigent Automation"

  /// `draft` for a new automation, filed into ``defaultProjectName`` where projects are offered.
  static func withDefaultProject(_ draft: AutomationDraftState, offered: ServerPages?)
    -> AutomationDraftState
  {
    guard offered?.automationProjects == true, draft.projectID.isEmpty else { return draft }
    var filed = draft
    filed.projectName = defaultProjectName
    return filed
  }

  /// `request` filed into the project `draft` names: the caller's project of that exact name,
  /// else a new one. `nil` when it could be neither found nor made.
  @MainActor
  static func withProject(
    _ request: OmnigentCoreFFI.AutomationDraft, draft: AutomationDraftState, pages: PagesStore,
    list: SessionListStore
  ) async -> OmnigentCoreFFI.AutomationDraft? {
    guard draft.projectID.isEmpty, let name = draft.projectName else { return request }
    let named = { (projects: [ProjectSummary]) in
      projects.first { $0.name == name && $0.id != nil }?.id
    }
    var filed = request
    if let id = named(pages.automationProjects.value ?? []) {
      filed.projectId = id
      return filed
    }
    if let created = await list.createProject(named: name), let id = created.id {
      filed.projectId = id
    } else {
      // Another window may have made it meanwhile.
      await pages.loadAutomationProjects()
      guard let id = named(pages.automationProjects.value ?? []) else { return nil }
      filed.projectId = id
    }
    await pages.loadAutomationProjects()
    return filed
  }
}
