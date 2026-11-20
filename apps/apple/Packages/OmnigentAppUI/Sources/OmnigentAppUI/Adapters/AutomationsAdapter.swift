import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Automations page over ``PagesStore``: the caller's list, Shared with me and the
/// templates, an automation's run history page (`automations_v2`), their actions, the editor
/// sheet and the share sheet.
struct AutomationsAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  /// Where the guide remembers it was seen.
  var defaults = UserDefaults.standard
  @State private var filter: AutomationsFilter = .all
  @State private var search = ""
  @State private var editing: Editing?
  @State private var draft = AutomationDraftState()
  @State private var isSaving = false
  @State private var saveError: String?
  @State private var detailID: String?
  @State private var sharing: SharingTarget?
  /// The web's toasts: "Automation created", "Run triggered…".
  @State private var banner: TransientBanner?
  /// Bumped by the guide's button to show it again.
  @State private var introRequests = 0
  /// Each trigger type's fields, kept while a new automation switches between them.
  @State private var typeDrafts: [String: AutomationDraftState] = [:]

  /// The sheet's subject: a new automation, or the one with this id.
  private struct Editing: Identifiable {
    let id: String
    var automationID: String? { id.isEmpty ? nil : id }
  }

  /// The automation the share sheet is for.
  private struct SharingTarget: Identifiable {
    let id: String
    let continuesSession: Bool
  }

  /// Opens a new automation from a session row, where the server starts runs from a copy of
  /// a session; `nil` hides the menu item.
  /// - Parameters:
  ///   - connection: The server.
  ///   - show: Shows the Automations page.
  /// - Returns: The row action.
  @MainActor
  static func createFromSession(
    _ connection: ConnectionStore, show: @escaping @MainActor () -> Void
  )
    -> (@MainActor (OmnigentUIComponents.SessionSummary) -> Void)?
  {
    guard let pages = connection.pages, let offered = pages.offered, offered.automations,
      offered.automationSourceSessions
    else { return nil }
    let list = connection.sessionList
    return { summary in
      let session = list.sessionsByID[summary.id]
      let configuration = session?.configuration
      pages.requestAutomation(
        from: AutomationSource(
          sessionID: summary.id, title: summary.title, agentID: configuration?.agentId,
          hostID: configuration?.hostId,
          workspace: session.map(\.workspace).flatMap { $0.isEmpty ? nil : $0 },
          model: configuration?.modelOverride, effort: configuration?.effort))
      show()
    }
  }

  /// Whether a session can be an automation's source (web `canCreateAutomationFromSession`):
  /// a listed session with an agent that no automation runs from yet. Side chats are never
  /// listed, and the menus leave out shared and archived sessions.
  static func offersAutomation(from session: OmnigentCoreFFI.SessionSummary?) -> Bool {
    guard let session, session.automationSourceId == nil else { return false }
    return session.configuration?.agentId?.isEmpty == false
  }

  var body: some View {
    if let pages = connection.pages {
      page(pages)
        // Read again each time the connection comes back, as what failed may load now.
        .task(id: connection.health.reconnections) {
          await pages.loadAutomations()
          await pages.loadAutomationCatalog()
          if pages.offered?.automationProjects == true { await pages.loadAutomationProjects() }
          if pages.offered?.automationTriggers == true { await pages.loadLongMessageHosts() }
        }
        .onAppear { openPendingSource(pages) }
        .onChange(of: pages.pendingAutomationSource) { openPendingSource(pages) }
        .onChange(of: connection.workflows?.pendingAutomation, initial: true) {
          openPendingWorkflow(pages)
        }
        .sheet(item: $editing) { target in editor(pages, target: target) }
        .sheet(item: $sharing) { target in shareSheet(pages, target: target) }
        .transientBanner($banner)
        // The Inbox's Open automation lands on that automation's page.
        .onChange(of: pages.requestedAutomationID, initial: true) { _, requested in
          guard let requested else { return }
          pages.requestedAutomationID = nil
          detailID = requested
        }
    } else {
      ContentUnavailableView("Automations are unavailable", systemImage: "clock")
    }
  }

  @ViewBuilder private func page(_ pages: PagesStore) -> some View {
    if let detailID, let automation = automation(pages, id: detailID) {
      AutomationDetailAdapter(
        pages: pages, automation: automation, open: open,
        back: { self.detailID = nil },
        edit: { edit(pages, id: detailID) },
        share: shareAction(pages, automation: automation),
        notify: { banner = TransientBanner(message: $0) })
    } else {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        AutomationsView(
          state: AutomationsMapping.state(
            pages: pages, filter: filter, search: search, now: context.date),
          actions: actions(pages))
      }
      .automationsIntro(connection, defaults: defaults, reopenRequests: introRequests)
    }
  }

  /// Starts a run from the list, saying so as the web's toast.
  private func runNow(_ pages: PagesStore, id: String) async {
    await Self.runNow(
      pages, id: id,
      started:
        "Run triggered, it will start shortly. Open automation details to check run history.",
      notify: { banner = TransientBanner(message: $0) })
  }

  /// Starts a run of `id`, saying so as the web's toast; a run in flight is not an error.
  @MainActor @discardableResult
  static func runNow(
    _ pages: PagesStore, id: String, started: String, notify: @escaping @MainActor (String) -> Void
  ) async -> Bool {
    if await pages.runAutomation(id) {
      notify(started)
      return true
    }
    if case .HttpStatus(409, _) = pages.automationError {
      notify("This run is already in progress")
    } else {
      notify("Couldn\u{2019}t start the run")
    }
    pages.dismissAutomationError()
    return false
  }

  /// The caller's automation, or one shared with them.
  private func automation(_ pages: PagesStore, id: String) -> Automation? {
    pages.automations.value?.first { $0.id == id }
      ?? pages.sharedAutomations.value?.first { $0.id == id }
  }

  private func editor(_ pages: PagesStore, target: Editing) -> some View {
    let saved = pages.automations.value?.first { $0.id == target.automationID }
    var inputs = AutomationEditorMapping.Inputs(
      draft: draft, saved: saved, sessionLink: sessionLink, isSaving: isSaving,
      saveError: saveError)
    inputs.switchTriggerEvent = { event in
      if let trigger = draft.trigger {
        draft.trigger = AutomationTriggerMapping.switched(trigger, toEvent: event)
      }
    }
    inputs.replaceSchedule = { draft.schedule = $0 }
    inputs.switchTriggerType = { switchTriggerType(pages, to: $0) }
    inputs.workflows = connection.workflows?.owned.value ?? []
    return AutomationEditorSheet(
      draft: $draft, context: AutomationEditorMapping.context(pages: pages, inputs: inputs),
      save: { save(pages, saved: saved) },
      cancel: { editing = nil }
    )
    .task(id: AutomationModelSource.of(draft, pages: pages)) {
      await AutomationModelSource.of(draft, pages: pages)?.load(pages)
    }
    .task {
      // The Workflow field lists the caller's saved workflows.
      if pages.offered?.workflows == true { await connection.workflows?.loadOwned() }
      if AutomationEditorMapping.showsMcpServices(pages.offered, draft: draft) {
        await pages.loadAutomationMcpServices()
      }
    }
    .onChange(of: draft.agentID) { _, agentID in
      // Settings are per harness: a switch drops them, and switching back restores them.
      AutomationsMapping.restoreOverrides(&draft, from: saved?.agentId == agentID ? saved : nil)
      if saved == nil {
        let agent = pages.automationCatalog.value?.agents.first { $0.id == agentID }
        draft.permissionMode = AutomationEditorMapping.newAutomationPermission(agent)
      }
    }
  }

  private func shareSheet(_ pages: PagesStore, target: SharingTarget) -> some View {
    let grants = pages.automationGrants[target.id]
    let state = AutomationShareState(
      people: (grants?.value ?? []).map {
        AutomationShareState.Person(id: $0.userId, name: $0.displayName)
      },
      continuesSession: target.continuesSession, isLoading: grants == .loading,
      isSaving: pages.isSavingAutomationGrant,
      errorMessage: pages.automationGrantError?.message ?? grants?.error?.message)
    return AutomationShareSheet(
      state: state,
      add: { person in Task { await pages.grantAutomationAccess(target.id, to: person) } },
      remove: { person in Task { await pages.revokeAutomationAccess(target.id, from: person) } },
      done: {
        pages.dismissAutomationGrantError()
        sharing = nil
      }
    )
    .task { await pages.loadAutomationGrants(target.id) }
  }

  /// Share for an automation the caller owns, on a server that shares them and hasn't turned
  /// sharing off; `nil` hides or disables it.
  private func shareAction(_ pages: PagesStore, automation: Automation) -> (@MainActor () -> Void)?
  {
    guard pages.offered?.automationSharing == true, !automation.sharedWithMe,
      ShareAdapter.unavailableReason(pages.offered, automation: automation) == nil
    else { return nil }
    let target = SharingTarget(id: automation.id, continuesSession: automation.continuesSession)
    return { sharing = target }
  }

  /// A session URL whose id the trigger's manager replaces with each worker's.
  private var sessionLink: String {
    SidebarAdapter.webURL(
      server: connection.connectedServer, sessionID: triggerSessionLinkPlaceholder()
    )?.absoluteString ?? ""
  }

  func actions(_ pages: PagesStore) -> AutomationsActions {
    var actions = AutomationsActions()
    actions.filter = {
      filter = $0
      search = $1
    }
    actions.create = {
      draft = AutomationsMapping.newDraft(catalog: pages.automationCatalog.value)
      present(id: "")
    }
    actions.createTrigger = { id in
      guard let source = AutomationTriggerMapping.source(id) else { return }
      let base = AutomationsMapping.newDraft(catalog: pages.automationCatalog.value)
      let schedule = AutomationsMapping.triggerSchedule(
        pages.offered, continuesSession: true, inSandbox: base.runsInSandbox)
      draft = AutomationTriggerMapping.newDraft(source, base: base, schedule: schedule)
      present(id: "")
      if pages.offered?.automationMcpServices == true {
        Task { await pages.loadAutomationMcpServices() }
      }
    }
    actions.edit = { edit(pages, id: $0) }
    if pages.offered?.automationsV2 == true {
      actions.openDetail = { detailID = $0 }
    }
    actions.setPaused = { id, paused in Task { await pages.setAutomationPaused(id, paused) } }
    actions.runNow = { id in Task { await runNow(pages, id: id) } }
    actions.showIntro = { introRequests += 1 }
    actions.delete = { id in Task { await pages.deleteAutomation(id) } }
    if pages.offered?.automationSharing == true {
      actions.share = { id in
        guard let automation = pages.automations.value?.first(where: { $0.id == id }) else {
          return
        }
        sharing = SharingTarget(id: id, continuesSession: automation.continuesSession)
      }
    }
    if pages.offered?.automationSharedWithMe == true {
      actions.loadShared = { Task { await pages.loadSharedAutomations() } }
      actions.loadMoreShared = { Task { await pages.loadMoreSharedAutomations() } }
    }
    actions.openSession = { open($0) }
    actions.retry = { Task { await pages.loadAutomations() } }
    actions.dismissError = { pages.dismissAutomationError() }
    return actions
  }

  private func edit(_ pages: PagesStore, id: String) {
    guard let automation = pages.automations.value?.first(where: { $0.id == id }) else { return }
    draft = AutomationsMapping.draft(automation, workflows: pages.offered?.workflows == true)
    present(id: id)
  }

}

/// Opening and saving the editor.
extension AutomationsAdapter {
  /// Opens the editor on the session a menu asked to make an automation from.
  /// New automation from a workflow (the Workflows page's Create automation): named for it, each
  /// run a new session that runs it as saved.
  private func openPendingWorkflow(_ pages: PagesStore) {
    guard let workflow = connection.workflows?.pendingAutomation else { return }
    connection.workflows?.pendingAutomation = nil
    detailID = nil
    draft = AutomationsMapping.workflowDraft(workflow, catalog: pages.automationCatalog.value)
    present(id: "")
  }

  private func openPendingSource(_ pages: PagesStore) {
    guard let source = pages.takePendingAutomationSource() else { return }
    detailID = nil
    var next = AutomationsMapping.newDraft(catalog: pages.automationCatalog.value)
    next.name = source.title
    next.continuesSession = false
    next.sourceSessionID = source.sessionID
    next.sourceSessionTitle = source.title
    if let agent = source.agentID { next.agentID = agent }
    if let host = source.hostID { next.hostID = host }
    next.workspace = source.workspace ?? ""
    next.model = source.model ?? ""
    next.effort = source.effort ?? ""
    draft = next
    present(id: "")
  }

  private func present(id: String) {
    saveError = nil
    typeDrafts = [:]
    editing = Editing(id: id)
  }

  /// Switches a new automation between a schedule (`nil`) and an integration, as the web's.
  private func switchTriggerType(_ pages: PagesStore, to id: String?) {
    let current = draft.trigger?.source
    draft = AutomationTriggerMapping.switchedType(
      draft, to: id, kept: &typeDrafts, offered: pages.offered)
    if id != nil, id != current, pages.offered?.automationMcpServices == true {
      Task { await pages.loadAutomationMcpServices() }
    }
  }

  private func save(_ pages: PagesStore, saved: Automation?) {
    guard !isSaving else { return }
    isSaving = true
    let sendsOverrides = AutomationEditorMapping.sendsOverrides(pages: pages, draft: draft)
    // A new trigger's hidden schedule follows where it runs.
    if saved == nil, draft.trigger != nil,
      AutomationsMapping.scheduleProblem(
        draft.schedule, saved: nil, anchored: pages.offered?.automationsV2 == true, now: .now,
        limits: AutomationsMapping.limits(draft, offered: pages.offered)) != nil
    {
      draft.schedule = AutomationsMapping.triggerSchedule(
        pages.offered, continuesSession: draft.continuesSession, inSandbox: draft.runsInSandbox)
    }
    let saving = AutomationEditorMapping.withWorkflowSessions(draft)
    let triggerPrompt =
      saving.trigger == nil
      ? ""
      : AutomationEditorMapping.triggerPrompt(
        pages: pages, draft: saving, saved: saved, sessionLink: sessionLink)
    let prompt = AutomationsMapping.prompt(
      saving, triggerPrompt: triggerPrompt,
      skillPrefix: AutomationEditorMapping.skillPrefix(pages, agentID: saving.agentID))
    let request = AutomationsMapping.request(
      saving, prompt: prompt, saved: saved,
      sessionModes: pages.offered?.automationSessionModes == true, sendsOverrides: sendsOverrides,
      sendsMcpServices: AutomationEditorMapping.showsMcpServices(pages.offered, draft: saving))
    let fromSession = saved == nil && draft.sourceSessionID != nil
    Task {
      let didSave = await pages.saveAutomation(request, editing: saved)
      isSaving = false
      if didSave {
        editing = nil
        if saved == nil { banner = TransientBanner(message: "Automation created") }
        // As the web, a new automation made from a session opens its page.
        if fromSession, pages.offered?.automationsV2 == true,
          let created = pages.automations.value?.first(where: {
            $0.sourceSessionId != nil
              && $0.name == request.name.trimmingCharacters(in: .whitespaces)
          })
        {
          detailID = created.id
        }
      } else {
        // The sheet shows the failure; the page banner would repeat it.
        saveError = pages.automationError?.message
        pages.dismissAutomationError()
      }
    }
  }
}
