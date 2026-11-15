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
      .onDisappear { form.closeNestedDraft(creation) }
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
          form.defaultSandboxProfile(creation.catalog.value)
        }
      }
  }
}
