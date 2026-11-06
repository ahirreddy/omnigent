import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// The right panel's device default: showing or hiding the panel becomes the default for the
/// next chat, as on the web, and a file opened from a link or the Inbox shows the panel.
struct WorkspacePanelDefaults: ViewModifier {
  let workspace: WorkspaceBrowserModel?
  /// The chat's own choice; `nil` until it shows or hides the panel.
  @Binding var choice: WorkspacePanelDefault?
  @AppStorage(InterfacePreferences.workspacePanelKey) private var panelDefault =
    WorkspacePanelDefault.collapsed

  func body(content: Content) -> some View {
    content
      .onChange(of: choice) { _, chosen in
        if let chosen, panelDefault != chosen { panelDefault = chosen }
      }
      .onChange(of: workspace?.document?.tabID, initial: true) { _, opened in
        if opened != nil, choice != .open { choice = .open }
      }
  }
}
