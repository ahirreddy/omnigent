#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Escape and Return in the fork and share sheets, which name no shortcut themselves: their
  /// toolbar placements decide what the keys press.
  @Suite("Inspector: keys in the fork and share sheets", .serialized)
  @MainActor
  struct InspectorSheetKeysTests {
    @Test("Escape cancels the fork sheet, and forks nothing")
    func forkEscape() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(), forkActions(log))
      defer { screen.close() }
      try screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(log.calls == ["selection a -", "cancel"])
      #expect(log.choices == nil)
    }

    @Test("Return presses Done in the share sheet when no field is being typed in")
    func shareReturn() throws {
      SystemSideEffects.reset()
      let log = SheetLog()
      let actions = ShareActions(addGrant: { log.calls.append("add \($0) \($1.rawValue)") })
      let view = Color.clear.sheet(isPresented: .constant(true)) {
        ShareSheet(state: ShareViewState(), actions: actions) { log.calls.append("done") }
      }
      let screen = OffscreenWindow(AnyView(view), width: 700, height: 700)
      defer { screen.close() }
      // The sheet opens with the Add people field focused, whose own Return adds a person.
      _ = screen.activeWindow.makeFirstResponder(nil)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.calls == ["done"])
    }
  }
#endif
