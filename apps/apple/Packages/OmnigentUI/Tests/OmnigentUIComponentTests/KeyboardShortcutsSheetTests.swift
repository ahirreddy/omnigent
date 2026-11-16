#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The shortcuts sheet over a window that can close it, as the app presents it.
  private struct ShortcutsHost: View {
    let isShown: EditedValue<Bool>

    var body: some View {
      Color.clear.sheet(isPresented: isShown.binding) { KeyboardShortcutsSheet() }
    }
  }

  @Suite("Keyboard shortcuts sheet, clicked", .serialized)
  @MainActor
  struct KeyboardShortcutsSheetTests {
    private func sheet(_ isShown: EditedValue<Bool>) throws -> OffscreenWindow<ShortcutsHost> {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(ShortcutsHost(isShown: isShown), width: 800, height: 800)
      try #require(MainLoop.settle(until: { screen.window.attachedSheet != nil }))
      return screen
    }

    @Test("Done closes the sheet")
    func done() throws {
      let isShown = EditedValue(true)
      let screen = try sheet(isShown)
      defer { screen.close() }
      #expect(try screen.shows("Keyboard shortcuts"))
      // The toolbar's Done is the sheet's last control.
      try screen.click(try #require(screen.controlFrames.last).center)
      #expect(MainLoop.settle(until: { screen.window.attachedSheet == nil }))
      #expect(!isShown.value)
    }
  }
#endif
