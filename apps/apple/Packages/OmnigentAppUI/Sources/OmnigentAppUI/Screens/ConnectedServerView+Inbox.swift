import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// Where the Inbox's agent-posted items and automation failures lead.
extension ConnectedServerView {
  /// Opens New session with `prompt` as its draft, as an agent's action does; nothing is sent.
  func startSession(drafting prompt: String) {
    connection.creation()?.composerDrafts[""] = prompt
    selectionBinding.wrappedValue = .newSession
  }

  /// Opens the Automations page on one automation.
  func openAutomation(_ automationID: String) {
    connection.pages?.requestedAutomationID = automationID
    selectionBinding.wrappedValue = .automations
  }
}
