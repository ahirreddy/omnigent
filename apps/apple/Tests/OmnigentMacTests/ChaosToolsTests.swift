#if DEBUG
  import AppKit
  import Testing

  #if OMNIGENT_CHROMIUM
    @testable import OmnigentMac
  #else
    @testable import OmnigentMacAppStore
  #endif

  /// What `ChaosInputTests` doesn't read: one-shot shortcuts, blank scripts and more bad lines.
  @MainActor
  struct ChaosScriptEdgeTests {
    @Test func aSingleShortcutAndNewlinesInTypedText() throws {
      let steps = try ChaosScript.parse("shortcut new tab\ntype hello\\r\nscroll -12.5 3")
      #expect(
        steps == [
          .shortcut("new tab", count: 1), .type("hello\r"), .scroll(delta: -12.5, ticks: 3),
        ])
    }

    @Test func emptyAndCommentOnlyScriptsHaveNoSteps() throws {
      #expect(try ChaosScript.parse("").isEmpty)
      #expect(try ChaosScript.parse("\n\n# only\n").isEmpty)
    }

    @Test(arguments: [
      "session", "session a b", "resize 100 b", "key", "scroll 1", "scroll 1 b", "type", "shortcut",
    ])
    func aBadLineIsReportedAsItIs(line: String) {
      #expect(throws: ChaosScript.Malformed(line: line)) {
        try ChaosScript.parse("session ok\n\(line)")
      }
    }
  }

  @MainActor
  struct ChaosRandomTests {
    @Test func aSeedReplaysTheSameChoices() {
      var first = SplitMix(seed: 42)
      var second = SplitMix(seed: 42)
      var other = SplitMix(seed: 43)
      let values = (0..<20).map { _ in first.next() }
      #expect(values == (0..<20).map { _ in second.next() })
      #expect(values != (0..<20).map { _ in other.next() })
    }

    @Test func boundsHold() {
      var random = SplitMix(seed: 1)
      #expect(random.int(below: 0) == 0)
      #expect(random.int(below: -3) == 0)
      for _ in 0..<500 {
        #expect((0..<7).contains(random.int(below: 7)))
        #expect((0...1).contains(random.unit))
      }
    }

    @Test func pastedTextIsTheSameForASeedAndHasTheLinesAsked() {
      let pasted = ChaosText.paste(lines: 5, seed: 9)
      #expect(pasted == ChaosText.paste(lines: 5, seed: 9))
      #expect(pasted.split(separator: "\n").count >= 5)
      #expect(pasted != ChaosText.paste(lines: 5, seed: 10))
      #expect(ChaosText.paste(lines: 0, seed: 1).hasPrefix("0 "))
    }
  }

  /// The walk must never reach what ends the run or leaves the VM.
  @MainActor
  struct ChaosMenuTests {
    private func menu(_ title: String, _ items: [String]) -> NSMenuItem {
      let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      menu.autoenablesItems = false
      for name in items { menu.addItem(withTitle: name, action: nil, keyEquivalent: "") }
      top.submenu = menu
      return top
    }

    @Test func theWalkNeverReachesWhatLeavesTheApp() {
      let existing = NSApp.mainMenu
      defer { NSApp.mainMenu = existing }
      let main = NSMenu(title: "Main")
      main.addItem(menu("", ["Quit Omnigent", "Check for Updates…", "Settings…"]))
      main.addItem(menu("File", ["New Session", "Sign Out", "Open…", "Local Server…"]))
      main.addItem(menu("Debug", ["Show Core Inspector"]))
      main.addItem(menu("Help", ["Omnigent Help"]))
      NSApp.mainMenu = main
      #expect(ChaosMenu.items().map(\.path) == ["App > Settings…", "File > New Session"])
    }

    @Test func noMenuHasNoItems() {
      let existing = NSApp.mainMenu
      defer { NSApp.mainMenu = existing }
      NSApp.mainMenu = nil
      #expect(ChaosMenu.items().isEmpty)
    }

    @Test func shortcutsLeaveOutQuitAndHide() {
      let shortcuts = ChaosMenu.shortcuts
      #expect(!shortcuts.isEmpty)
      #expect(shortcuts.contains { $0.name == "new tab" })
      #expect(!shortcuts.contains { $0.name.contains("quit") || $0.name.contains("hide") })
      #expect(Set(shortcuts.map(\.name)).count == shortcuts.count, "a name is ambiguous")
    }
  }

  @MainActor
  struct ChaosWindowsTests {
    private func window() -> NSWindow {
      let window = NSWindow(
        contentRect: CGRect(x: -20_000, y: -20_000, width: 600, height: 400),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      return window
    }

    @Test func aWindowHasADescription() {
      let window = window()
      #expect(ChaosLog.describe(window).hasPrefix("<NSWindow level=0"))
      window.title = "Named"
      #expect(ChaosLog.describe(window) == "\"Named\"")
    }

    @Test func focusNamesWhatHasTheKeyboard() {
      let window = window()
      #expect(ChaosLog.focus(in: window).hasPrefix("NSWindow"))
      let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
      window.contentView?.addSubview(text)
      #expect(window.makeFirstResponder(text))
      #expect(ChaosLog.focus(in: window).contains("NSTextView"))
      #expect(ChaosLog.describeTextFocus(in: window).contains("takes no text"))
    }

    @Test func theLookChangeCyclesAndSaysSo() {
      let existing = NSApp.appearance
      defer { NSApp.appearance = existing }
      var lines: [String] = []
      ChaosWindows.change(window(), choice: 4, look: 1) { lines.append($0) }
      #expect(NSApp.appearance?.name == .aqua)
      ChaosWindows.change(window(), choice: 4, look: 3) { lines.append($0) }
      #expect(NSApp.appearance == nil)
      #expect(lines == ["appearance NSAppearanceNameAqua", "appearance system"])
    }

    @Test func theSmallestChangeResizesAndSaysSo() {
      let window = window()
      var lines: [String] = []
      ChaosWindows.change(window, choice: 3, look: 0) { lines.append($0) }
      #expect(lines == ["window smallest"])
      #expect(window.frame.width == ChaosWindows.smallestSize(of: window).width)
    }
  }

  @MainActor
  struct ChaosLogFileTests {
    private func temporaryFile() -> URL {
      FileManager.default.temporaryDirectory.appending(path: "chaos-\(UUID().uuidString).log")
    }

    @Test func linesAreWrittenInOrder() throws {
      let url = temporaryFile()
      defer { try? FileManager.default.removeItem(at: url) }
      let log = try #require(ChaosLogFile(path: url.path))
      log.write("one")
      log.write("two")
      #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
    }

    @Test func aPathThatCannotBeWrittenIsNil() {
      #expect(ChaosLogFile(path: "/nonexistent-\(UUID().uuidString)/log") == nil)
    }

    /// `-OmnigentChaosLog` names where a nil title's stack goes.
    @Test func aNilMenuTitleIsAppendedToTheLog() throws {
      let url = temporaryFile()
      defer {
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.removeObject(forKey: "OmnigentChaosLog")
      }
      #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
      UserDefaults.standard.set(url.path, forKey: "OmnigentChaosLog")
      ChaosLog.recordNilMenuTitle()
      #expect(try String(contentsOf: url, encoding: .utf8).contains("NIL MENU TITLE"))
    }
  }
#endif
