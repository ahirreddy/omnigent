import OmnigentAppUI
import OmnigentUIComponents
import SwiftUI

/// View > Show Browser (Option-Command-B): a browser tab in the key server window. The browser
/// used to be its own window; it is now a tab like any other.
struct BrowserCommands: Commands {
  @FocusedValue(\.tabCommands) private var tabs

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button("Show Browser") { tabs?.openBrowser?() }
        .keyboardShortcut("b", modifiers: [.command, .option])
        .disabled(tabs?.openBrowser == nil)
    }
  }
}
