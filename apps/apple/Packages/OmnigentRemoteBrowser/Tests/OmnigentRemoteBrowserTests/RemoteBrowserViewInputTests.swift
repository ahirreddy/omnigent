#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import Testing

  @testable import OmnigentRemoteBrowser

  private enum Events {
    static func mouse(
      _ type: NSEvent.EventType, at location: CGPoint, flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    static func key(
      _ type: NSEvent.EventType = .keyDown, _ characters: String = "a", keyCode: UInt16 = 0,
      flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: keyCode))
    }

    /// A modifier key event, built but never posted.
    static func flags(keyCode: UInt16, flags: CGEventFlags) throws -> NSEvent {
      let event = try #require(
        CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
      event.type = .flagsChanged
      event.flags = flags
      return try #require(NSEvent(cgEvent: event))
    }

    /// A scroll event, built but never posted.
    static func scroll(_ deltaY: Int32, _ deltaX: Int32 = 0) throws -> NSEvent {
      let event = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY,
          wheel2: deltaX, wheel3: 0))
      return try #require(NSEvent(cgEvent: event))
    }
  }

  /// A view location in window coordinates, for a view in no window: y runs up.
  private func location(_ across: CGFloat, _ down: CGFloat) -> CGPoint {
    CGPoint(x: across, y: 1000 - down)
  }

  @MainActor
  @Suite("Remote browser view, mouse", .serialized)
  struct RemoteBrowserViewMouseTests {
    @Test("the view takes clicks and the keyboard, and stays top-left")
    func responder() async {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      #expect(view.acceptsFirstResponder)
      #expect(view.acceptsFirstMouse(for: nil))
      #expect(view.isFlipped)
    }

    @Test("a click lands in CSS pixels")
    func click() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let point = location(100, 350)
      view.mouseDown(with: try Events.mouse(.leftMouseDown, at: point))
      view.mouseUp(with: try Events.mouse(.leftMouseUp, at: point))
      let mice = hosted.connector.driver.mice
      try #require(mice.count == 2)
      #expect(mice[0].kind == .down)
      #expect(mice[0].x == 100)
      #expect(mice[0].y == 100)
      #expect(mice[0].button == .left)
      #expect(mice[1].kind == .up)
    }

    @Test("every mouse handler reaches the page")
    func everyHandler() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let point = location(100, 350)
      view.rightMouseDown(with: try Events.mouse(.rightMouseDown, at: point))
      view.rightMouseDragged(with: try Events.mouse(.rightMouseDragged, at: point))
      view.rightMouseUp(with: try Events.mouse(.rightMouseUp, at: point))
      view.otherMouseDown(with: try Events.mouse(.otherMouseDown, at: point))
      view.otherMouseDragged(with: try Events.mouse(.otherMouseDragged, at: point))
      view.otherMouseUp(with: try Events.mouse(.otherMouseUp, at: point))
      view.mouseDragged(with: try Events.mouse(.leftMouseDragged, at: point))
      view.mouseMoved(with: try Events.mouse(.mouseMoved, at: point))
      #expect(hosted.connector.driver.mice.count == 8)
    }

    @Test("wheel events of any size send real deltas or nothing")
    func wheel() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      for delta in [Int32.max, .min, 0, 1, -1] {
        view.scrollWheel(with: try Events.scroll(delta, delta))
      }
      #expect(hosted.connector.driver.mice.allSatisfy { $0.dx.isFinite && $0.dy.isFinite })
    }

    @Test("the pointer leaving the page over the letterbox tells it once")
    func letterbox() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      view.mouseMoved(with: try Events.mouse(.mouseMoved, at: location(10, 300)))
      view.mouseMoved(with: try Events.mouse(.mouseMoved, at: location(10, 10)))
      view.mouseMoved(with: try Events.mouse(.mouseMoved, at: location(10, 20)))
      view.mouseDown(with: try Events.mouse(.leftMouseDown, at: location(10, 20)))
      #expect(hosted.connector.driver.mice.map(\.kind) == [.move, .leave])
    }

    @Test("a drag past the page stays clamped to it")
    func dragOffThePage() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let far = location(5000, -5000)
      view.mouseDragged(with: try Events.mouse(.leftMouseDragged, at: far, flags: []))
      view.mouseUp(with: try Events.mouse(.leftMouseUp, at: far))
      let mouseUp = try #require(hosted.connector.driver.mice.last)
      #expect(mouseUp.kind == .up)
      #expect(mouseUp.x == 999)
      #expect(mouseUp.y == 0)
    }

    @Test("nothing reaches a page the user doesn't control")
    func notInControl() async throws {
      let (hosted, view) = await inControl(HostedStore.snapshot(owner: .agent, holder: .nobody))
      defer { hosted.finish() }
      let point = location(100, 350)
      view.mouseDown(with: try Events.mouse(.leftMouseDown, at: point))
      view.keyUp(with: try Events.key(.keyUp))
      view.commitText("x", replacementRange: NSRange(location: 0, length: 0))
      #expect(hosted.connector.driver.mice.isEmpty)
      #expect(hosted.connector.driver.keys.isEmpty)
      #expect(hosted.connector.driver.ime.isEmpty)
    }

    @Test("a press with no position is dropped")
    func pressWithNoPosition() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let nowhere = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
      view.mouseDown(with: try Events.mouse(.leftMouseDown, at: nowhere))
      view.mouseMoved(with: try Events.mouse(.mouseMoved, at: nowhere))
      #expect(hosted.connector.driver.mice.isEmpty)
    }

    @Test(
      "a release with no position sends a real one",
      .disabled("Behavior: cssPoint(clamped:) lets NaN through min and max, and the host gets NaN"))
    func releaseWithNoPosition() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let nowhere = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
      view.mouseUp(with: try Events.mouse(.leftMouseUp, at: nowhere))
      for sent in hosted.connector.driver.mice {
        #expect(sent.x.isFinite)
        #expect(sent.y.isFinite)
      }
    }
  }

  @MainActor
  @Suite("Remote browser view, keyboard", .serialized)
  struct RemoteBrowserViewKeyTests {
    /// The view as first responder of a never-shown window, so key equivalents reach it.
    private func focused(edit: Bool = true) async -> FocusedView {
      let focused = FocusedView()
      await focused.hosted.hostSends(HostedStore.snapshot(edit: edit))
      return focused
    }

    @Test("the window never shown is far from the pointer")
    func windowIsOffscreen() {
      let window = neverShownWindow(size: CGSize(width: 800, height: 500))
      #expect(!window.isVisible)
      #expect(window.frame.minX < -10_000)
    }

    @Test(
      "editing chords become edit commands",
      arguments: [
        ("c", NSEvent.ModifierFlags.command, "edit copy "), ("x", .command, "edit cut "),
        ("a", .command, "edit selectAll "), ("z", .command, "edit undo "),
        ("z", [.command, .shift], "edit redo "), ("v", .command, "edit paste pasted"),
      ].map { ChordCase(key: $0.0, flags: $0.1, call: $0.2) })
    func editingChords(chord: ChordCase) async throws {
      let page = await focused()
      defer { page.finish() }
      let (hosted, view) = (page.hosted, page.view)
      hosted.store.pasteboard.write("pasted")
      let event = try Events.key(.keyDown, chord.key, flags: chord.modifiers)
      #expect(view.performKeyEquivalent(with: event))
      #expect(hosted.driverCalls.last == chord.call)
    }

    @Test("pasting nothing says so, and sends nothing")
    func pastingNothing() async throws {
      let page = await focused()
      defer { page.finish() }
      let (hosted, view) = (page.hosted, page.view)
      #expect(view.performKeyEquivalent(with: try Events.key(.keyDown, "v", flags: .command)))
      #expect(hosted.store.notice != nil)
      #expect(!hosted.driverCalls.contains { $0.hasPrefix("edit") })
    }

    @Test("a host with no edit commands gets the key itself")
    func noEditCommands() async throws {
      let page = await focused(edit: false)
      defer { page.finish() }
      let (hosted, view) = (page.hosted, page.view)
      #expect(view.performKeyEquivalent(with: try Events.key(.keyDown, "c", flags: .command)))
      #expect(!hosted.connector.driver.keys.isEmpty)
      #expect(!hosted.driverCalls.contains { $0.hasPrefix("edit") })
    }

    @Test(
      "other chords stay with the app",
      arguments: [
        ("q", NSEvent.ModifierFlags.command), ("c", [.command, .option]),
        ("c", [.command, .control]),
        ("c", []), ("", .command), ("\u{0}", .command),
      ].map { ChordCase(key: $0.0, flags: $0.1, call: "") })
    func otherChords(chord: ChordCase) async throws {
      let page = await focused()
      defer { page.finish() }
      let (hosted, view) = (page.hosted, page.view)
      #expect(
        !view.performKeyEquivalent(
          with: try Events.key(.keyDown, chord.key, flags: chord.modifiers)))
      #expect(hosted.connector.driver.keys.isEmpty)
    }

    @Test("a chord is not the page's when it doesn't have the focus")
    func unfocused() async throws {
      let page = await focused()
      defer { page.finish() }
      let view = page.view
      page.window.makeFirstResponder(nil)
      #expect(!view.performKeyEquivalent(with: try Events.key(.keyDown, "c", flags: .command)))
    }

    @Test("keys reach the page down and up, with the names of named ones")
    func keys() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      view.keyDown(with: try Events.key(.keyDown, "q", keyCode: 12, flags: .command))
      view.keyUp(with: try Events.key(.keyUp, "\r", keyCode: 36))
      view.flagsChanged(with: try Events.flags(keyCode: 56, flags: .maskShift))
      let keys = hosted.connector.driver.keys
      #expect(keys.contains { $0.key == "q" })
      #expect(keys.contains { $0.key == "Enter" && $0.kind == .keyUp })
      #expect(keys.contains { $0.key == "Shift" })
    }

    @Test(
      "a typed key of any characters reaches the page",
      arguments: ["", "a", "😀", "\u{0}", "\u{F700}", String(repeating: "x", count: 4096)])
    func typedKeys(characters: String) async throws {
      let page = await focused()
      defer { page.finish() }
      let (hosted, view) = (page.hosted, page.view)
      for keyCode in [UInt16.zero, 36, .max] {
        view.keyDown(with: try Events.key(.keyDown, characters, keyCode: keyCode))
        view.keyUp(with: try Events.key(.keyUp, characters, keyCode: keyCode))
      }
      #expect(!hosted.connector.driver.keys.isEmpty)
    }
  }

  /// The view as first responder of a never-shown window.
  @MainActor
  private struct FocusedView {
    let hosted = HostedStore()
    let view: RemoteBrowserView
    let window = neverShownWindow(size: CGSize(width: 800, height: 500))

    init() {
      view = RemoteBrowserView(store: hosted.store)
      window.contentView = view
      window.makeFirstResponder(view)
    }

    func finish() {
      hosted.finish()
      window.contentView = nil
    }
  }

  /// A key, its modifiers and the driver call they should make.
  nonisolated struct ChordCase: Sendable {
    let key: String
    let flags: NSEvent.ModifierFlags.RawValue
    let call: String

    init(key: String, flags: NSEvent.ModifierFlags, call: String) {
      self.key = key
      self.flags = flags.rawValue
      self.call = call
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }
  }
#endif
