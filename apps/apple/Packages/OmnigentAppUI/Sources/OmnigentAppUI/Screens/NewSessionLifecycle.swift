import OmnigentCoreFFI
import OmnigentStores
import SwiftUI

/// The new-session page's reactions: opening a created session (filing it in a label-only
/// project first), taking a project the sidebar asked for, filling the folder per host, and
/// reading what a chosen sandbox offers.
struct NewSessionLifecycle: ViewModifier {
  let form: NewSessionForm
  let creation: CreationStore
  let connection: ConnectionStore
  /// Opens a created session whose first message went out.
  let opened: @MainActor (String) -> Void
  /// Opens a created nested agent whose first message didn't go out; `nil` leaves the page up.
  var openedUnfinished: (@MainActor (String) -> Void)?

  func body(content: Content) -> some View {
    content
      .onChange(of: creation.phase) { _, phase in
        if case .failed = phase { form.nestedCreateFailed(creation) }
        guard case .created(let sessionID, let firstMessageError) = phase else { return }
        form.nestedCreated(sessionID, creation)
        form.fileInLabelProject(sessionID, list: connection.sessionList)
        guard let open = firstMessageError == nil ? opened : openedUnfinished else { return }
        creation.reset()
        form.name = ""
        open(sessionID)
      }
      // The server's policy can change while the composer is open.
      .onChange(of: creation.catalog) { form.enforceNestedPolicy(creation) }
      .onDisappear {
        form.closeNestedDraft(creation)
        creation.composingProject = nil
      }
      .onChange(of: form.project, initial: true) { _, project in
        creation.composingProject = form.nested == nil ? project : nil
      }
      .onChange(of: creation.pendingProject, initial: true) { _, next in
        guard let next, form.nested == nil else { return }
        creation.pendingProject = nil
        Task { await form.applyProject(next, creation) }
      }
      .task(id: form.needsHost(creation)) {
        await form.waitForHost(creation)
      }
      .task(id: form.folderSeedTrigger(creation, list: connection.sessionList)) {
        await form.seedFolder(creation, list: connection.sessionList)
      }
      .task(id: form.isSandbox ? form.sandbox.provider ?? "" : nil) {
        if form.isSandbox, let sandboxes = form.sandboxes {
          await form.sandbox.load(creation.catalog.value, sandboxes: sandboxes)
          await form.defaultSandboxProfile(creation.catalog.value)
        }
      }
      .task(id: form.sandboxProfileCheck(creation)) {
        if form.isSandbox, let sandboxes = form.sandboxes {
          await form.sandbox.checkChosenProfile(creation.catalog.value, sandboxes: sandboxes)
        }
      }
      .onChange(of: creation.phase) { _, phase in
        // A refused launch may mean a profile or the harness configuration changed: read both
        // again, as the web does.
        guard case .failed = phase, form.isSandbox else { return }
        Task { await form.reloadSandboxChoices(creation) }
      }
  }
}
