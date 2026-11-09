#if os(macOS)
  import AppKit
  import Testing

  @testable import OmnigentViewTesting

  @MainActor
  @Suite("Product code can't reach the person using this Mac", .serialized)
  struct SystemSideEffectsTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
    }

    @Test("the clipboard stays private to the test")
    func clipboard() {
      let real = NSPasteboard(name: .general)
      let before = real.changeCount
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString("copied", forType: .string)
      #expect(real.changeCount == before)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "copied")
      #expect(NSPasteboard.general.name != real.name)
    }

    @Test("opening and revealing are recorded")
    func workspace() throws {
      let link = try #require(URL(string: "https://example.com/a"))
      let file = URL(filePath: "/tmp/a.txt")
      #expect(NSWorkspace.shared.open(link))
      NSWorkspace.shared.open(link, configuration: .init()) { _, error in
        #expect(error == nil)
      }
      NSWorkspace.shared.activateFileViewerSelecting([file])
      #expect(SystemSideEffects.record.openedURLs == [link, link])
      #expect(SystemSideEffects.record.revealedURLs == [file])
    }

    @Test("panels and alerts answer without showing")
    func modals() {
      let alert = NSAlert()
      alert.messageText = "Delete?"
      #expect(alert.runModal() == .alertFirstButtonReturn)
      SystemSideEffects.answer(alert: .alertSecondButtonReturn, panel: .OK)
      #expect(alert.runModal() == .alertSecondButtonReturn)
      #expect(NSOpenPanel().runModal() == .OK)
      #expect(NSSavePanel().runModal() == .OK)
      #expect(SystemSideEffects.record.alertMessages == ["Delete?", "Delete?"])
      #expect(SystemSideEffects.record.panelCount == 2)
      SystemSideEffects.reset()
      #expect(NSOpenPanel().runModal() == .cancel)
    }

    @Test("focus, new windows, menus and quitting are recorded")
    func application() {
      let app = NSApplication.shared
      app.activate()
      app.terminate(nil)
      let window = NSWindow(
        contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.title = "Logs"
      window.makeKeyAndOrderFront(nil)
      #expect(!window.isVisible)
      let shown = NSMenu().popUp(positioning: nil, at: .zero, in: nil)
      #expect(!shown)
      let record = SystemSideEffects.record
      #expect(record.activationCount == 1)
      #expect(record.terminationCount == 1)
      #expect(record.shownWindowTitles == ["Logs"])
      #expect(record.poppedUpMenuCount == 1)
    }
  }
#endif
