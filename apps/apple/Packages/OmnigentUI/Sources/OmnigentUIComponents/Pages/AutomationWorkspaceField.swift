import SwiftUI

/// The editor's Workspace row (the web's workspace picker): a folder on the pinned host, typed
/// or chosen with Browse… from the host's folders; empty runs in the host's home directory.
struct AutomationWorkspaceField: View {
  @Binding var draft: AutomationDraftState
  let browse: (@MainActor (String?) async -> Result<FolderListing, FolderBrowseError>)?
  @State private var isBrowsing = false

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      TextField("Workspace", text: $draft.workspace, prompt: Text("No workspace"))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 280)
        .disabled(draft.hostID.isEmpty && draft.workspace.isEmpty)
        .help("An absolute path on the host. Empty runs in the host\u{2019}s home directory.")
        .accessibilityIdentifier("automation-workspace")
      if browse != nil {
        Button("Browse\u{2026}") { isBrowsing = true }
          .disabled(draft.hostID.isEmpty)
          .help(draft.hostID.isEmpty ? "Pick a host before pinning a workspace." : "")
          .accessibilityIdentifier("automation-workspace-browse")
      }
    }
    // Another folder or host needs its own check, so Random worktree turns off, as the web's.
    .onChange(of: draft.workspace) { draft.baseBranch = nil }
    .onChange(of: draft.hostID) { draft.baseBranch = nil }
    .sheet(isPresented: $isBrowsing) {
      if let browse {
        FolderBrowserView(
          initialPath: draft.workspace.isEmpty ? nil : draft.workspace, load: browse,
          choose: { path in
            draft.workspace = path
            isBrowsing = false
          },
          cancel: { isBrowsing = false })
      }
    }
  }
}
