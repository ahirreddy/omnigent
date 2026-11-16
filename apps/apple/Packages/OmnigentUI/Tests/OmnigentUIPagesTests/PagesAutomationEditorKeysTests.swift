#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Automation editor, keys", .serialized)
  @MainActor
  struct PagesAutomationEditorKeysTests {
    private let log = ActionLog()

    private func sheet(_ draft: AutomationDraftState) -> OffscreenWindow<AutomationEditorSheet> {
      SystemSideEffects.reset()
      let context = AutomationEditorContext(
        agents: [AutomationOption(id: "a1", name: "Claude Code")], supportsSessionModes: true,
        describe: { _ in "" })
      let edited = EditedValue(draft)
      let log = log
      return OffscreenWindow(
        AutomationEditorSheet(
          draft: edited.binding, context: context, save: { log.record("save") },
          cancel: { log.record("cancel") }), width: 700, height: 1_500)
    }

    // Each key is pressed with no field focused: off screen, Return in a focused field doesn't
    // reach the default button.
    @Test("Return saves a form that is complete, and not one that is missing its prompt")
    func returnSaves() throws {
      let blocked = sheet(AutomationDraftState(name: "Brief", agentID: "a1"))
      defer { blocked.close() }
      _ = blocked.activeWindow.makeFirstResponder(nil)
      try blocked.press(keyCode: 36, characters: "\r")
      #expect(log.entries.isEmpty)
      let screen = sheet(AutomationDraftState(name: "Brief", prompt: "Go", agentID: "a1"))
      defer { screen.close() }
      _ = screen.activeWindow.makeFirstResponder(nil)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries == ["save"])
    }

    @Test("Escape cancels, whether or not the form could be saved")
    func escapeCancels() throws {
      let screen = sheet(AutomationDraftState(name: "Brief"))
      defer { screen.close() }
      _ = screen.activeWindow.makeFirstResponder(nil)
      try screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(log.entries == ["cancel"])
    }
  }
#endif
