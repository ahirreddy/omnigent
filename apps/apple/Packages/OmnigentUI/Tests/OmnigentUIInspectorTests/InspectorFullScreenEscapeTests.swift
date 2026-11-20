#if os(macOS)
  import AppKit
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: Escape leaves a file's full screen")
  @MainActor
  struct InspectorFullScreenEscapeTests {
    private typealias Watcher = FullScreenEscapeWatcher.WatcherView

    @MainActor private final class ExitCount {
      var value = 0
    }

    @Test("A bare Escape leaves full screen only while a file fills it")
    func bareEscape() {
      let watcher = Watcher()
      let exits = ExitCount()
      watcher.exit = { exits.value += 1 }
      let escape = Watcher.escapeKeyCode
      #expect(!watcher.handle(keyCode: escape, modifiers: [], responder: nil))
      watcher.isActive = true
      #expect(watcher.handle(keyCode: escape, modifiers: [], responder: nil))
      #expect(exits.value == 1)
      // Another key, or Escape with a modifier, is not this key.
      #expect(!watcher.handle(keyCode: 36, modifiers: [], responder: nil))
      #expect(!watcher.handle(keyCode: escape, modifiers: .command, responder: nil))
      #expect(exits.value == 1)
      #expect(watcher.hitTest(.zero) == nil)
    }

    @Test("Editable text keeps its Escape; a read-only viewer's selection does not")
    func editableText() {
      let watcher = Watcher()
      let exits = ExitCount()
      watcher.exit = { exits.value += 1 }
      watcher.isActive = true
      let editor = NSTextView()
      #expect(!watcher.handle(keyCode: Watcher.escapeKeyCode, modifiers: [], responder: editor))
      editor.isEditable = false
      #expect(watcher.handle(keyCode: Watcher.escapeKeyCode, modifiers: [], responder: editor))
      #expect(exits.value == 1)
    }
  }
#endif
