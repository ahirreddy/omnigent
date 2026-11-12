#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Keys as a keyboard and the menu bar deliver them, which differ from the named key alone.
  @Suite("Composer: keys as a keyboard sends them", .serialized)
  @MainActor
  struct ComposerRealKeyTests {
    private let log = ComposerActionLog()

    @Test("Shift-Tab from a keyboard, which sends the backtab character, moves to the next mode")
    func keyboardShiftTabCycles() throws {
      let model = ComposerScreenModel(state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressShiftTab()
      #expect(log.events == ["mode:full-access"])
    }

    private func tabKey(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        characters: "\u{19}", charactersIgnoringModifiers: "\u{19}", isARepeat: false,
        keyCode: ShiftTabWatcher.WatcherView.tabKeyCode)
      return try #require(event)
    }

    @Test("Shift-Tab is taken ahead of focus navigation while the editor has the keyboard")
    func shiftTabAheadOfFocusNavigation() throws {
      let watcher = ShiftTabWatcher.WatcherView()
      let log = log
      watcher.perform = {
        log.events.append("cycle")
        return true
      }
      #expect(try !watcher.handle(tabKey(.shift)))
      watcher.isActive = true
      #expect(try watcher.handle(tabKey(.shift)))
      #expect(log.events == ["cycle"])
      // A plain Tab, and Shift-Tab with another modifier, are not this key.
      #expect(try !watcher.handle(tabKey([])))
      #expect(try !watcher.handle(tabKey([.shift, .command])))
      #expect(log.events == ["cycle"])
      // With no mode to move to, the key goes on to move the focus.
      watcher.perform = { false }
      #expect(try !watcher.handle(tabKey(.shift)))
      #expect(watcher.hitTest(.zero) == nil)
    }

    @Test("A Command shortcut that shows a composer gives it the keyboard; an arrow key does not")
    func showingKeys() {
      #expect(ComposerShowingKey.keepsFocusElsewhere(isKeyDown: true, hasCommand: false))
      #expect(!ComposerShowingKey.keepsFocusElsewhere(isKeyDown: true, hasCommand: true))
      #expect(!ComposerShowingKey.keepsFocusElsewhere(isKeyDown: false, hasCommand: false))
    }
  }
#endif
