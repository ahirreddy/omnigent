#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// The Browser menu's key equivalents. A menu bar hands each key press to its menus, and the
  /// menu whose item has that key runs it: here the key goes to the Browser menu the same way.
  @MainActor
  @Suite("Browser menu keys", .serialized)
  struct BrowserTabCommandsKeyTests {
    private typealias Screen = OffscreenWindow<AnyView>

    /// The Browser menu's items as the Mac app builds them: Find and Zoom are the app's own.
    private func hosted(_ fixture: TabFixture?, sheet: Binding<BrowserTabSheet?>? = nil) -> Screen {
      OffscreenWindow(
        AnyView(
          Menu("Browser") {
            BrowserTabCommandItems(tab: fixture?.model, sheet: sheet, includesFindAndZoom: false)
          }
          .menuStyle(.borderlessButton)), width: 200, height: 40)
    }

    /// Presses a key with the menu built, and says whether one of its items took it. The event
    /// is made as the keyboard makes it, from the key's code and the modifiers held, so its
    /// characters are the keyboard layout's own.
    private func press(
      keyCode: CGKeyCode, _ flags: CGEventFlags = .maskCommand, in menu: NSMenu, _ screen: Screen
    ) async throws -> Bool {
      let pressed = try #require(
        CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
      pressed.flags = flags
      let event = try #require(NSEvent(cgEvent: pressed))
      let taken = menu.performKeyEquivalent(with: event)
      await screen.catchUp()
      return taken
    }

    /// The letter keys' codes on a Mac keyboard.
    private enum Key {
      static let letterD: CGKeyCode = 2
      static let letterI: CGKeyCode = 34
      static let letterJ: CGKeyCode = 38
      static let letterL: CGKeyCode = 37
      static let letterP: CGKeyCode = 35
      static let letterR: CGKeyCode = 15
      static let letterU: CGKeyCode = 32
      static let letterY: CGKeyCode = 16
    }

    @Test("Command-L, R, Shift-R, D, P and Option-Command-U and I each run their own item")
    func tabKeys() async throws {
      let fixture = try TabFixture()
      fixture.environment.onOpenTab = { _, _ in }
      let tab = try fixture.tab
      let model = fixture.model
      let screen = hosted(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let menu = try screen.popupMenu()

      let focus = model.omniboxFocusRequest
      #expect(try await press(keyCode: Key.letterL, in: menu, screen))
      #expect(model.omniboxFocusRequest == focus + 1)
      #expect(tab.commands.isEmpty, "Open Location runs nothing on the page")
      #expect(try await press(keyCode: Key.letterR, in: menu, screen))
      #expect(tab.commands == ["reload"])
      #expect(try await press(keyCode: Key.letterR, [.maskCommand, .maskShift], in: menu, screen))
      #expect(tab.commands == ["reload", "hardReload"])
      #expect(try await press(keyCode: Key.letterD, in: menu, screen))
      #expect(model.isBookmarked)
      #expect(try await press(keyCode: Key.letterP, in: menu, screen))
      #expect(tab.commands.last == "print")
      #expect(
        try await press(keyCode: Key.letterU, [.maskCommand, .maskAlternate], in: menu, screen))
      #expect(tab.commands.contains("viewSource"))
      #expect(
        try await press(keyCode: Key.letterI, [.maskCommand, .maskAlternate], in: menu, screen))
      #expect(tab.commands.last == "devtools")
    }

    @Test("Command-Y asks the tab for its history; a key the menu doesn't have is left alone")
    func historyKey() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let recorder = SheetRecorder()
      let screen = hosted(
        fixture, sheet: Binding(get: { recorder.value }, set: { recorder.value = $0 }))
      defer { screen.close() }
      await screen.catchUp()
      let menu = try screen.popupMenu()
      #expect(try await press(keyCode: Key.letterY, in: menu, screen))
      #expect(recorder.value == .history)
      #expect(try await !press(keyCode: Key.letterJ, in: menu, screen))
      #expect(tab.commands.isEmpty)
    }

    @Test("with no browser tab focused the keys run nothing")
    func noTab() async throws {
      SystemSideEffects.install()
      let recorder = SheetRecorder()
      let screen = hosted(
        nil, sheet: Binding(get: { recorder.value }, set: { recorder.value = $0 }))
      defer { screen.close() }
      await screen.catchUp()
      let menu = try screen.popupMenu()
      // An item that is off may still take its key, so that nothing else does: it runs nothing.
      _ = try await press(keyCode: Key.letterY, in: menu, screen)
      #expect(recorder.value == nil)
    }
  }
#endif
