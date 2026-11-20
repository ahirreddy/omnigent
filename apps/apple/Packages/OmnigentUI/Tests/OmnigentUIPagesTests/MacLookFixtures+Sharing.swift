import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Sharing, presence, reconnecting and the automation editor's defaults.
extension LookFixtures {
  /// The share sheet of an automation's session: the managed notice and the workspace files
  /// switch.
  static var shareManaged: some View {
    var state = ShareViewState(
      workspaceFiles: true,
      grants: [ShareGrant(id: "g1", principal: "dev@example.com", role: .read)],
      link: URL(string: "https://omnigent.example.com/sessions/s1"))
    state.managedBy = "Nightly triage"
    var actions = ShareActions(
      setGeneralAccess: { _ in }, setWorkspaceFiles: { _ in }, addGrant: { _, _ in },
      setRole: { _, _ in }, removeGrant: { _ in })
    actions.openManagingAutomation = {}
    return ShareSheet(state: state, actions: actions, done: {}).omnigentAppearance(.omni)
  }

  /// The reconnect sheet for a session whose host was this Mac.
  static var reconnectThisMac: some View {
    var actions = SessionLivenessActions(checkAgain: {}, fork: {})
    actions.reconnectThisMachine = { nil }
    let notice = SessionLivenessNotice(
      liveness: .hostOffline(isOwner: true), sessionID: "s1",
      serverURL: "https://omnigent.example.com", wrapper: nil, harness: "claude-native")
    return ReconnectSessionSheet(notice: notice, actions: actions, show: { _ in })
      .omnigentAppearance(.omni)
  }

  /// Who else is reading: three avatars, one idle, and the rest as "+N".
  static var presence: some View {
    let names = [
      "ada@example.com", "grace.hopper@example.com", "linus@example.com", "margaret@example.com",
      "alan@example.com",
    ]
    let viewers = names.enumerated().map { index, name in
      SectionReading.Viewer(id: "v\(index)", name: name, isIdle: index == 1)
    }
    return PresenceAvatars(viewers: viewers)
      .padding(Theme.Spacing.medium)
      .omnigentAppearance(.omni)
  }

  /// A new automation filed into the default project, in this device's zone, with Browse and
  /// Random worktree under Advanced.
  static var newAutomationDefaults: some View {
    var draft = AutomationUXFixtures.scheduleDraft
    draft.projectID = ""
    draft.projectName = "Omnigent Automation"
    draft.timezone = "America/New_York"
    draft.workspace = "/Users/dev/code/garden"
    draft.baseBranch = AutomationWorktreeRow.baseRef
    var context = AutomationUXFixtures.editorContext()
    context.browseWorkspace = { _ in .failure(FolderBrowseError(message: "Not in a render")) }
    context.worktreeCheck = .repository
    return AutomationEditorForm(
      editor: AutomationEditorSheet(
        draft: .constant(draft), context: context, save: {}, cancel: {}),
      showsAdvanced: .constant(true))
  }

  /// A sandboxed automation with the provider's notice under Advanced.
  static var sandboxNotice: some View {
    var draft = AutomationUXFixtures.scheduleDraft
    draft.hostID = ""
    draft.runsInSandbox = true
    var context = AutomationUXFixtures.editorContext()
    context.sandboxNotice =
      "Sandboxes stop after 2 hours, so long runs may not finish. Results stay in the session."
    // Advanced settings open, where the notice sits.
    return AutomationEditorForm(
      editor: AutomationEditorSheet(
        draft: .constant(draft), context: context, save: {}, cancel: {}),
      showsAdvanced: .constant(true))
  }
}
