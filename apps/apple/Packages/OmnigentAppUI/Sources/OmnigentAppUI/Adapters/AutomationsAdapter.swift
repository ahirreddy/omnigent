import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Automations page over ``PagesStore``: the list, an automation's run history page
/// (`automations_v2`), their actions and the editor sheet.
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

  /// The sheet's subject: a new automation, or the one with this id.
  private struct Editing: Identifiable {
    let id: String
    var automationID: String? { id.isEmpty ? nil : id }
  }

  var body: some View {
    if let pages = connection.pages {
      page(pages)
        .task {
          await pages.loadAutomations()
          await pages.loadAutomationCatalog()
          if pages.offered?.automationProjects == true { await pages.loadAutomationProjects() }
        }
        .sheet(item: $editing) { target in editor(pages, target: target) }
    } else {
      ContentUnavailableView("Automations are unavailable", systemImage: "clock")
    }
  }

  @ViewBuilder private func page(_ pages: PagesStore) -> some View {
    if let detailID, let automation = pages.automations.value?.first(where: { $0.id == detailID }) {
      AutomationDetailAdapter(
        pages: pages, automation: automation, open: open,
        back: { self.detailID = nil },
        edit: { edit(pages, id: detailID) })
    } else {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        AutomationsView(
          state: AutomationsMapping.state(
            pages: pages, filter: filter, search: search, now: context.date),
          actions: actions(pages))
      }
      .automationsIntro(connection, defaults: defaults)
    }
  }

  private func editor(_ pages: PagesStore, target: Editing) -> some View {
    let saved = pages.automations.value?.first { $0.id == target.automationID }
    let inputs = AutomationEditorMapping.Inputs(
      draft: draft, saved: saved, sessionLink: sessionLink, isSaving: isSaving,
      saveError: saveError)
    return AutomationEditorSheet(
      draft: $draft, context: AutomationEditorMapping.context(pages: pages, inputs: inputs),
      save: { save(pages, saved: saved) },
      cancel: { editing = nil }
    )
    .task(id: modelsKey(pages)) {
      guard let key = modelsKey(pages) else { return }
      await pages.loadAutomationModels(agentID: key.agentID, hostID: key.hostID)
    }
    .onChange(of: draft.agentID) { _, agentID in
      // Settings are per harness: a switch drops them, and switching back restores them.
      AutomationsMapping.restoreOverrides(&draft, from: saved?.agentId == agentID ? saved : nil)
    }
  }

  /// The agent and host whose models the Advanced section lists, when the agent takes them.
  private func modelsKey(_ pages: PagesStore) -> ModelsKey? {
    guard !draft.hostID.isEmpty, !draft.runsInSandbox,
      AutomationEditorMapping.sendsOverrides(pages.automationCatalog.value, agentID: draft.agentID)
    else { return nil }
    return ModelsKey(agentID: draft.agentID, hostID: draft.hostID)
  }

  private struct ModelsKey: Hashable {
    let agentID: String
    let hostID: String
  }

  /// A session URL whose id the trigger's manager replaces with each worker's.
  private var sessionLink: String {
    SidebarAdapter.webURL(
      server: connection.connectedServer, sessionID: triggerSessionLinkPlaceholder()
    )?.absoluteString ?? ""
  }

  private func actions(_ pages: PagesStore) -> AutomationsActions {
    var actions = AutomationsActions()
    actions.filter = {
      filter = $0
      search = $1
    }
    actions.create = { suggestion in
      draft = AutomationsMapping.newDraft(suggestion, catalog: pages.automationCatalog.value)
      present(id: "")
    }
    actions.createTrigger = { id in
      guard let source = AutomationTriggerMapping.source(id) else { return }
      let base = AutomationsMapping.newDraft(nil, catalog: pages.automationCatalog.value)
      draft = AutomationTriggerMapping.newDraft(source, base: base)
      present(id: "")
    }
    actions.edit = { edit(pages, id: $0) }
    if pages.offered?.automationsV2 == true {
      actions.openDetail = { detailID = $0 }
    }
    actions.setPaused = { id, paused in Task { await pages.setAutomationPaused(id, paused) } }
    actions.runNow = { id in Task { await pages.runAutomation(id) } }
    actions.delete = { id in Task { await pages.deleteAutomation(id) } }
    actions.openSession = { open($0) }
    actions.retry = { Task { await pages.loadAutomations() } }
    actions.dismissError = { pages.dismissAutomationError() }
    return actions
  }

  private func edit(_ pages: PagesStore, id: String) {
    guard let automation = pages.automations.value?.first(where: { $0.id == id }) else { return }
    draft = AutomationsMapping.draft(automation)
    present(id: id)
  }

  private func present(id: String) {
    saveError = nil
    editing = Editing(id: id)
  }

  private func save(_ pages: PagesStore, saved: Automation?) {
    guard !isSaving else { return }
    isSaving = true
    let catalog = pages.automationCatalog.value
    let sendsOverrides = AutomationEditorMapping.sendsOverrides(catalog, agentID: draft.agentID)
    let prompt =
      draft.trigger == nil
      ? draft.prompt
      : AutomationTriggerMapping.prompt(
        draft, sessionLink: sessionLink, sendsOverrides: sendsOverrides)
    let request = AutomationsMapping.request(
      draft, prompt: prompt, saved: saved,
      sessionModes: pages.offered?.automationSessionModes == true, sendsOverrides: sendsOverrides)
    Task {
      let didSave = await pages.saveAutomation(request, editing: saved)
      isSaving = false
      if didSave {
        editing = nil
      } else {
        // The sheet shows the failure; the page banner would repeat it.
        saveError = pages.automationError?.message
        pages.dismissAutomationError()
      }
    }
  }
}
