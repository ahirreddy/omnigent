#if os(iOS)
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import Testing
  import UIKit

  @testable import OmnigentRemoteBrowser

  private func press(
    _ typed: String, _ usage: UIKeyboardHIDUsage, _ flags: UIKeyModifierFlags = []
  ) -> Set<UIPress> {
    ScriptedKey(typed, usage, flags).pressed
  }

  @MainActor
  @Suite("Remote page keyboard: the software keyboard", .serialized)
  struct RemoteSoftwareKeyboardTests {
    private func focus(_ mode: TextInputKind, on page: TouchPage) async {
      var snapshot = page.hosted.store.snapshot
      snapshot.textInput.mode = mode
      await page.hosted.hostSends(snapshot)
    }

    @Test("the view owns an invisible keyboard proxy and can take the hardware keyboard")
    func installed() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let proxy = page.view.keyboardProxy
      #expect(page.view.canBecomeFirstResponder)
      #expect(proxy.superview === page.view)
      #expect(proxy.owner === page.view)
      #expect(proxy.frame.size == CGSize(width: 1, height: 1))
      #expect(proxy.canBecomeFirstResponder)
      #expect(proxy.hasText)
      #expect(!proxy.isAccessibilityElement)
      #expect(proxy.accessibilityIdentifier == "remote-browser.keyboard")
    }

    @Test("a field the user just tapped brings the keyboard up, matched to the field")
    func keyboardFollowsFocus() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let proxy = page.view.keyboardProxy
      page.tap(100, 350)
      await focus(.url, on: page)
      #expect(proxy.isFirstResponder)
      #expect(proxy.keyboardType == .URL)
      #expect(proxy.returnKeyType == .go)
      await focus(.search, on: page)
      #expect(proxy.isFirstResponder)
      #expect(proxy.keyboardType == .webSearch)
      #expect(proxy.returnKeyType == .search)
    }

    @Test("a field that takes focus on its own, with no tap, leaves the keyboard down")
    func noTapNoKeyboard() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      await focus(.email, on: page)
      #expect(!page.view.keyboardProxy.isFirstResponder)
      #expect(page.view.keyboardProxy.keyboardType == .emailAddress)
    }

    @Test("the keyboard goes down once the field has stayed unfocused, and comes back with it")
    func keyboardHidesAndReturns() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let proxy = page.view.keyboardProxy
      page.tap(100, 350)
      await focus(.text, on: page)
      #expect(proxy.isFirstResponder)
      page.view.lastTapAt = nil

      await focus(.none, on: page)
      #expect(proxy.isFirstResponder)
      #expect(page.view.keyboardHide != nil)
      #expect(await page.wait { page.view.isFirstResponder })
      #expect(!proxy.isFirstResponder)
      #expect(page.view.keyboardHiddenAt != nil)
      #expect(page.view.keyboardHide == nil)

      // A resize can blur and refocus the field: focus soon after the hide brings it back.
      await focus(.text, on: page)
      #expect(proxy.isFirstResponder)
    }

    @Test("a field that is focused again at once never loses the keyboard")
    func briefBlur() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let proxy = page.view.keyboardProxy
      page.tap(100, 350)
      await focus(.text, on: page)
      await focus(.none, on: page)
      #expect(page.view.keyboardHide != nil)
      await focus(.text, on: page)
      #expect(page.view.keyboardHide == nil)
      await page.screen.settle(.milliseconds(550))
      #expect(proxy.isFirstResponder)
      #expect(page.view.keyboardHiddenAt == nil)
    }

    @Test("when control is lost the keyboard waits as for a blur, and stays for a focused field")
    func keyboardWithoutControl() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.tap(100, 350)
      await focus(.text, on: page)
      #expect(page.view.keyboardProxy.isFirstResponder)
      var snapshot = page.hosted.store.snapshot
      snapshot.control = RemoteBrowserControl(
        owner: .agent, holder: .nobody, userId: nil, handoff: nil)
      await page.hosted.hostSends(snapshot)
      #expect(page.view.keyboardHide != nil)
      // Only a field that is unfocused when the wait ends hides the keyboard.
      await page.screen.settle(.milliseconds(550))
      #expect(page.view.keyboardProxy.isFirstResponder)
      #expect(page.view.keyboardHide == nil)
    }

    @Test("typed text is committed as text, with Return and Tab as keys in between")
    func typing() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let driver = page.hosted.connector.driver
      page.view.keyboardProxy.insertText("ab\ncd\te\r")
      #expect(driver.ime.map(\.op) == [.commit, .commit, .commit])
      #expect(driver.ime.map(\.text) == ["ab", "cd", "e"])
      #expect(
        driver.keys.map(\.kind)
          == [.rawKeyDown, .char, .keyUp, .rawKeyDown, .keyUp, .rawKeyDown, .char, .keyUp])
      #expect(
        driver.keys.map(\.key)
          == ["Enter", "Enter", "Enter", "Tab", "Tab", "Enter", "Enter", "Enter"])
      #expect(driver.keys.map(\.hidUsage) == [0x28, 0x28, 0x28, 0x2B, 0x2B, 0x28, 0x28, 0x28])
      #expect(driver.keys.map(\.text) == [nil, "\r", nil, nil, nil, nil, "\r", nil])
      let order = driver.log.filter { $0 == "ime" || $0 == "key" }
      let enter = ["key", "key", "key"]
      #expect(order == ["ime"] + enter + ["ime", "key", "key", "ime"] + enter)
    }

    @Test("Delete on the software keyboard is a Backspace key, whatever the field holds")
    func backspace() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.view.keyboardProxy.deleteBackward()
      let keys = page.hosted.connector.driver.keys
      #expect(keys.map(\.kind) == [.rawKeyDown, .keyUp])
      #expect(keys.map(\.key) == ["Backspace", "Backspace"])
      #expect(keys.map(\.hidUsage) == [0x2A, 0x2A])
      #expect(keys.allSatisfy { $0.modifiers == 0 && !$0.repeat && $0.text == nil })
    }

    @Test("a proxy with no page types nothing")
    func orphanProxy() {
      let proxy = RemoteKeyboardProxy(frame: .zero)
      proxy.insertText("a")
      proxy.deleteBackward()
      proxy.pressesBegan(press("a", .keyboardA), with: nil)
      proxy.pressesEnded(press("a", .keyboardA), with: nil)
      #expect(proxy.owner == nil)
    }

    @Test(
      "each kind of field gets its keyboard and return key",
      arguments: [
        (TextInputKind.tel, UIKeyboardType.phonePad, UIReturnKeyType.default),
        (.url, .URL, .go), (.email, .emailAddress, .default), (.numeric, .numberPad, .default),
        (.decimal, .decimalPad, .default), (.search, .webSearch, .search),
      ])
    func keyboardTraits(mode: TextInputKind, type: UIKeyboardType, returnKey: UIReturnKeyType) {
      let proxy = RemoteKeyboardProxy(frame: .zero)
      #expect(!proxy.configure(for: .text))
      #expect(!proxy.configure(for: .none))
      #expect(proxy.configure(for: mode))
      #expect(proxy.keyboardType == type)
      #expect(proxy.returnKeyType == returnKey)
      #expect(!proxy.configure(for: mode))
      #expect(proxy.configure(for: .text))
      #expect(proxy.keyboardType == .default)
      #expect(proxy.returnKeyType == .default)
      #expect(proxy.autocorrectionType == .no)
      #expect(proxy.autocapitalizationType == .none)
      #expect(proxy.spellCheckingType == .no)
      #expect(proxy.smartQuotesType == .no)
      #expect(proxy.smartDashesType == .no)
      #expect(proxy.smartInsertDeleteType == .no)
    }
  }

  @MainActor
  @Suite("Remote page keyboard: hardware keys and edit actions", .serialized)
  struct RemoteHardwareKeyboardTests {
    @Test("a letter is a key down with its character, then a key up")
    func letter() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let driver = page.hosted.connector.driver
      page.view.pressesBegan(press("A", .keyboardA, [.shift, .alphaShift]), with: nil)
      page.view.pressesEnded(press("A", .keyboardA, [.shift, .alphaShift]), with: nil)
      #expect(driver.keys.map(\.kind) == [.rawKeyDown, .char, .keyUp])
      #expect(driver.keys.map(\.key) == ["A", "A", "A"])
      #expect(driver.keys.map(\.text) == [nil, "A", nil])
      #expect(driver.keys.map(\.hidUsage) == [0x04, 0x04, 0x04])
      let held: RemoteModifiers = [.shift, .capsLock]
      #expect(driver.keys.allSatisfy { $0.modifiers == held.rawValue })
    }

    @Test("Return types a carriage return; other named keys and chords type nothing")
    func namedKeys() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let driver = page.hosted.connector.driver
      #expect(page.view.sendKeys(press("\r", .keyboardReturnOrEnter), down: true))
      #expect(driver.keys.map(\.key) == ["Enter", "Enter"])
      #expect(driver.keys.last?.text == "\r")

      #expect(page.view.sendKeys(press("", .keyboardLeftArrow, [.alternate]), down: true))
      #expect(driver.keys.count == 3)
      #expect(driver.keys.last?.key == "ArrowLeft")
      #expect(driver.keys.last?.modifiers == RemoteModifiers.alt.rawValue)

      #expect(page.view.sendKeys(press("k", .keyboardK, [.command, .control]), down: true))
      #expect(driver.keys.count == 4)
      #expect(driver.keys.last?.kind == .rawKeyDown)
      let chord: RemoteModifiers = [.meta, .control]
      #expect(driver.keys.last?.modifiers == chord.rawValue)

      // A key that names nothing and types nothing.
      #expect(page.view.sendKeys(press("", .keyboardHelp), down: true))
      #expect(driver.keys.last?.key == "Unidentified")
      #expect(driver.keys.count == 5)
    }

    @Test("the editing chords are left to the edit actions when the host has them")
    func editChords() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let driver = page.hosted.connector.driver
      for letter in ["a", "c", "v", "x", "z", "C"] {
        #expect(!page.view.sendKeys(press(letter, .keyboardC, .command), down: true))
      }
      // Not handled here, so UIKit's own handling runs and nothing is sent.
      page.view.pressesBegan(press("c", .keyboardC, .command), with: nil)
      page.view.pressesEnded(press("c", .keyboardC, .command), with: nil)
      page.view.keyboardProxy.pressesBegan(press("c", .keyboardC, .command), with: nil)
      page.view.keyboardProxy.pressesEnded(press("c", .keyboardC, .command), with: nil)
      #expect(driver.keys.isEmpty)

      // A host without edit commands gets the chord as keys.
      let plain = try await TouchPage(HostedStore.snapshot(edit: false))
      defer { plain.finish() }
      #expect(plain.view.sendKeys(press("c", .keyboardC, .command), down: true))
      #expect(plain.hosted.connector.driver.keys.map(\.kind) == [.rawKeyDown])
    }

    @Test("keys reach the page through the keyboard proxy too, and not at all without control")
    func proxyAndControl() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      page.view.keyboardProxy.pressesBegan(press("b", .keyboardB), with: nil)
      page.view.keyboardProxy.pressesEnded(press("b", .keyboardB), with: nil)
      #expect(page.hosted.connector.driver.keys.map(\.kind) == [.rawKeyDown, .char, .keyUp])
      // A press with no key (a remote's button) is not the page's.
      #expect(!page.view.sendKeys([ScriptedPress(key: nil)], down: true))

      let watching = try await TouchPage(HostedStore.snapshot(owner: .agent, holder: .nobody))
      defer { watching.finish() }
      #expect(!watching.view.sendKeys(press("b", .keyboardB), down: true))
      #expect(watching.hosted.connector.driver.keys.isEmpty)
    }

    @Test("Undo and Redo are key commands that edit the remote page")
    func undoRedo() async throws {
      let page = try await TouchPage()
      defer { page.finish() }
      let commands = try #require(page.view.keyCommands)
      #expect(commands.map(\.title) == ["Undo", "Redo"])
      #expect(commands.map(\.input) == ["z", "z"])
      #expect(commands.map(\.modifierFlags) == [.command, [.command, .shift]])
      for command in commands {
        let action = try #require(command.action)
        _ = unsafe page.view.perform(action)
      }
      #expect(page.hosted.driverCalls.suffix(2) == ["edit undo ", "edit redo "])

      let plain = try await TouchPage(HostedStore.snapshot(edit: false))
      defer { plain.finish() }
      #expect(plain.view.keyCommands?.isEmpty == true)
    }

    private func selecting(editable: Bool, collapsed: Bool) -> RemoteBrowserSnapshot {
      var snapshot = HostedStore.snapshot()
      snapshot.selection = RemoteSelection(
        editable: editable, collapsed: collapsed, length: collapsed ? 0 : 4,
        rect: RemoteRect(x: 100, y: 100, width: 50, height: 20))
      return snapshot
    }

    @Test("the edit menu offers what the page's selection allows")
    func editActionsOffered() async throws {
      UIPasteboard.general.string = "from this device"
      let copy = #selector(UIResponder.copy(_:))
      let cut = #selector(UIResponder.cut(_:))
      let paste = #selector(UIResponder.paste(_:))
      let selectAll = #selector(UIResponder.selectAll(_:))
      func offered(_ page: TouchPage) -> [Bool] {
        [copy, cut, paste, selectAll].map { page.view.canPerformAction($0, withSender: nil) }
      }

      let editing = try await TouchPage(selecting(editable: true, collapsed: false))
      defer { editing.finish() }
      #expect(offered(editing) == [true, true, true, true])

      let reading = try await TouchPage(selecting(editable: false, collapsed: false))
      defer { reading.finish() }
      #expect(offered(reading) == [true, false, false, true])

      let caret = try await TouchPage(selecting(editable: true, collapsed: true))
      defer { caret.finish() }
      #expect(offered(caret) == [false, false, true, true])

      // A host that reports no selection: assume one, editable only inside a focused field.
      let unknown = try await TouchPage()
      defer { unknown.finish() }
      #expect(offered(unknown) == [true, false, false, true])
      var focused = HostedStore.snapshot()
      focused.textInput.mode = .text
      await unknown.hosted.hostSends(focused)
      #expect(offered(unknown) == [true, true, true, true])
      UIPasteboard.general.items = []
      #expect(offered(unknown) == [true, true, false, true])

      let bold = #selector(UIResponder.toggleBoldface(_:))
      #expect(!unknown.view.canPerformAction(bold, withSender: nil))
    }

    @Test("Copy, Cut, Paste and Select All edit the remote page with this device's pasteboard")
    func editActionsRun() async throws {
      let page = try await TouchPage(selecting(editable: true, collapsed: false))
      defer { page.finish() }
      let pasteboard = try #require(page.hosted.store.pasteboard as? MemoryPasteboard)
      pasteboard.text = "local text"
      page.view.copy(nil)
      page.view.cut(nil)
      page.view.paste(nil)
      page.view.selectAll(nil)
      #expect(
        page.hosted.driverCalls.suffix(4)
          == ["edit copy ", "edit cut ", "edit paste local text", "edit selectAll "])
      // Select All then offers Copy for the new selection, above it.
      #expect(page.editMenu.presentedAt.isEmpty)
      #expect(await page.wait { !page.editMenu.presentedAt.isEmpty })
      #expect(page.editMenu.presentedAt == [CGPoint(x: 125, y: 350)])
    }
  }
#endif
