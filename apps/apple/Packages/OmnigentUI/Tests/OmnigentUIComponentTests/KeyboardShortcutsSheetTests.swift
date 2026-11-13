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
      screen.settle(0.3)
      try #require(screen.window.attachedSheet != nil)
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
      screen.settle(0.3)
      #expect(!isShown.value)
      #expect(screen.window.attachedSheet == nil)
    }
  }
#endif
