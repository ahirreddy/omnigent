import OmnigentWorkspaceUI
import SwiftUI

/// Reloads a chat's workspace when an agent changes files. The count is read in this body, so
/// a change runs this modifier and renders nothing of the chat or of its tab.
struct ChangedFilesFollower: ViewModifier {
  /// The connection's count of file changes.
  let revision: @MainActor () -> Int
  let workspace: WorkspaceBrowserModel?

  func body(content: Content) -> some View {
    content.onChange(of: revision()) {
      guard let workspace else { return }
      Task { await workspace.changedFilesInvalidated() }
    }
  }
}
