import OmnigentTerminalUI
import OmnigentUIComponents
import SwiftUI

/// The harness TUI when the core reports it ready, else the package's placeholder.
struct ConversationHarnessTerminal: View {
  let surface: TerminalSurfaceController?
  let harness: String?
  let error: GhosttyError?

  var body: some View {
    if let surface {
      SessionTerminalView(controller: surface)
    } else {
      VStack {
        TerminalPlaceholderView(harness: harness)
        if let error {
          Label(String(describing: error), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
  }
}
