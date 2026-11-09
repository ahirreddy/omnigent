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

  func body(content: Content) -> some View {
    content
      .onChange(of: creation.phase) { _, phase in
        guard case .created(let sessionID, let firstMessageError) = phase else { return }
        form.fileInLabelProject(sessionID, list: connection.sessionList)
        if firstMessageError == nil {
          creation.reset()
          opened(sessionID)
        }
      }
      .onChange(of: creation.pendingProject, initial: true) { _, next in
        guard let next else { return }
        creation.pendingProject = nil
        Task { await form.applyProject(next, creation) }
      }
      .task(id: form.needsHost(creation)) {
        await form.waitForHost(creation)
      }
      .task(id: form.folderSeedTrigger(creation)) {
        await form.seedFolder(creation, sessions: connection.sessionList.visible)
      }
      .task(id: form.isSandbox ? form.sandbox.provider ?? "" : nil) {
        if form.isSandbox, let sandboxes = form.sandboxes {
          await form.sandbox.load(creation.catalog.value, sandboxes: sandboxes)
        }
      }
  }
}
