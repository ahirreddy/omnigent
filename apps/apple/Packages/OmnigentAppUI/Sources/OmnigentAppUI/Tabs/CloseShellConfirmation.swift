import OmnigentStores
import OmnigentTerminalStores
import SwiftUI

/// "Close shell?" before a shell tab closes, as the web asks: closing ends the shell and any
/// process in it, so Close Shell deletes the terminal as well as the tab.
struct CloseShellConfirmation: ViewModifier {
  let session: ServerSession
  /// Reports a terminal that could not be ended.
  let fail: @MainActor (String) -> Void

  /// The shown session's tabs, where a shell close is asked.
  private var tabs: TabStore? { session.tabs.current }

  func body(content: Content) -> some View {
    let tabs = tabs
    content.alert(
      "Close shell?",
      isPresented: Binding(
        get: { tabs?.closingShell != nil },
        set: { if !$0, tabs?.closingShell != nil { tabs?.closingShell = nil } })
    ) {
      Button("Cancel", role: .cancel) { tabs?.closingShell = nil }
      Button("Close Shell", role: .destructive) { closeShell() }
    } message: {
      Text(message)
    }
  }

  private var message: String {
    let name = tabs?.closingShell.flatMap { tabs?.tab($0)?.title }
    let subject = name.map { "This terminates \($0)" } ?? "This terminates the shell"
    return "\(subject) and ends any process running in it. This can\u{2019}t be undone."
  }

  func closeShell() {
    guard let tabs, let id = tabs.closingShell, let shell = tabs.closeShell(id),
      let terminals = session.terminalStores[shell.sessionID]?.terminals
    else { return }
    Task {
      await terminals.delete(shell.terminalID)
      if let error = terminals.lastError {
        fail("The shell could not be closed: \(error.message)")
      }
    }
  }
}
