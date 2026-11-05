import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// The right panel's device default: showing or hiding the panel becomes the default for the
/// next chat, as on the web, and a file opened from a link or the Inbox shows the panel.
struct WorkspacePanelDefaults: ViewModifier {
  let workspace: WorkspaceBrowserModel?
  @Binding var showsInspector: Bool
  @AppStorage(InterfacePreferences.workspacePanelKey) private var panelDefault =
    WorkspacePanelDefault.collapsed

  func body(content: Content) -> some View {
    content
      .onChange(of: showsInspector) { _, shown in
        let preferred: WorkspacePanelDefault = shown ? .open : .collapsed
        if panelDefault != preferred { panelDefault = preferred }
      }
      .onChange(of: workspace?.document?.tabID, initial: true) { _, opened in
        if opened != nil, !showsInspector { showsInspector = true }
      }
  }
}
