#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// A tab in a fresh environment with an active engine tab, for driving its views off screen.
  @MainActor
  struct TabFixture {
    let environment: BrowserEnvironment
    let provider: FakeProvider
    let model: BrowserTabModel

    init(url: String? = "https://a.example/page", engine: BrowserEngineKind = .system) throws {
      (environment, provider) = try makeEnvironment(engine: engine)
      model = environment.makeTab(url: try url.map(testURL))
      model.activate()
    }

    var tab: FakeTab {
      get throws { try #require(model.tab as? FakeTab) }
    }
  }

  extension OffscreenWindow {
    /// Sends a key equivalent as `NSApplication` does: to the window, not its first responder.
    /// - Returns: Whether something took it.
    @discardableResult
    func shortcut(
      _ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = .command
    ) throws -> Bool {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
      let handled = window.performKeyEquivalent(with: try #require(event))
      settle(0.02)
      return handled
    }

    /// The buttons AppKit draws (the borderless style's), top to bottom and left to right. Popup
    /// buttons are left out, since clicking one opens its menu.
    var buttons: [NSButton] {
      allViews.compactMap { $0 as? NSButton }
        .filter { !($0 is NSPopUpButton) && !$0.isHiddenOrHasHiddenAncestor }
        .sorted { frame(of: $0).origin.isBefore(frame(of: $1).origin) }
    }

    /// The editable text fields, top to bottom and left to right.
    var fields: [NSTextField] {
      allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        .sorted { frame(of: $0).origin.isBefore(frame(of: $1).origin) }
    }

    /// A `Menu`'s items, built as for opening it but without opening it.
    /// - Parameter index: The menu's position among the popup buttons, top to bottom.
    /// - Returns: The menu; run an item with `choose(_:in:)`.
    /// - Throws: `OffscreenWindowError.notFound` when there is no such menu.
    func popupMenu(at index: Int = 0) throws -> NSMenu {
      let popups = allViews.compactMap { $0 as? NSPopUpButton }
        .sorted { frame(of: $0).origin.isBefore(frame(of: $1).origin) }
      guard popups.indices.contains(index), let menu = popups[index].menu else {
        throw OffscreenWindowError.notFound("menu \(index) of \(popups.count)")
      }
      // SwiftUI fills the menu when its button's cell says it will show; nothing is shown here.
      let willShow = Selector(("popUpButtonCell:willShowMenu:"))
      guard let delegate = menu.delegate as? NSObject, delegate.responds(to: willShow) else {
        throw OffscreenWindowError.notFound("a SwiftUI menu at \(index)")
      }
      _ = delegate.perform(willShow, with: popups[index].cell, with: menu)
      return menu
    }

    /// Clicks a button by its position in `buttons`.
    func clickButton(at index: Int) throws {
      let found = buttons
      guard found.indices.contains(index) else {
        throw OffscreenWindowError.notFound("button \(index) of \(found.count)")
      }
      try click(found[index])
    }

    /// Focuses a field by its position in `fields`.
    func focusField(at index: Int = 0) throws {
      let found = fields
      guard found.indices.contains(index) else {
        throw OffscreenWindowError.notFound("field \(index) of \(found.count)")
      }
      try click(found[index])
    }

    /// The progress bars, top to bottom.
    var progressBars: [NSProgressIndicator] {
      allViews.compactMap { $0 as? NSProgressIndicator }
    }

    /// Whether a sheet is up.
    var hasSheet: Bool { window.attachedSheet != nil }

    /// Waits out the sheet's slide, which runs on timers.
    func letSheetSettle() async {
      for _ in 0..<8 {
        await catchUp()
        settle(0.05)
      }
    }

    /// Buttons of the default style over a platform view, which SwiftUI draws itself and marks
    /// only with a focus ring view; `controlFrames` doesn't list them.
    var drawnButtons: [CGRect] {
      allViews.filter { String(describing: Swift.type(of: $0)) == "_FocusRingView" }
        .map { frame(of: $0) }
        .sorted { $0.origin.isBefore($1.origin) }
    }

    /// Clicks a button by its position in `drawnButtons`.
    func clickDrawnButton(at index: Int) throws {
      let found = drawnButtons
      guard found.indices.contains(index) else {
        throw OffscreenWindowError.notFound("drawn button \(index) of \(found.count)")
      }
      try click(CGPoint(x: found[index].midX, y: found[index].midY))
    }

    /// Whether a drawn button takes clicks: SwiftUI gives only an enabled one its focus proxy.
    func drawnButtonIsEnabled(at index: Int) async -> Bool {
      // The proxies only change when the key view loop is rebuilt.
      window.recalculateKeyViewLoop()
      await catchUp()
      let target = drawnButtons[index]
      return controlFrames.contains {
        abs($0.minX - target.minX) < 2 && abs($0.minY - target.minY) < 2
      }
    }

    /// The menu a right click on a list row would open: the table answers for its rows.
    /// - Parameter point: A point in the row, from the top left of the window.
    /// - Returns: The first menu up the view tree.
    /// - Throws: `OffscreenWindowError.eventUnavailable` when AppKit declines the event.
    func rowMenu(at point: CGPoint) throws -> NSMenu? {
      let event = NSEvent.mouseEvent(
        with: .rightMouseDown, location: host.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1,
        clickCount: 1, pressure: 1)
      guard let event else { throw OffscreenWindowError.eventUnavailable }
      var view = host.hitTest(host.convert(point, to: host.superview))
      while let current = view {
        if let menu = current.menu(for: event) { return menu }
        view = current.superview
      }
      return nil
    }

    /// Selects the focused field's text, so typing replaces it.
    func selectFieldText() {
      (window.firstResponder as? NSText)?.selectAll(nil)
    }

    func pressReturn() throws { try press(keyCode: 36, characters: "\r") }
    func pressEscape() throws { try press(keyCode: 53, characters: "\u{1b}") }
    func pressDownArrow() throws { try press(keyCode: 125, characters: "\u{F701}") }
    func pressUpArrow() throws { try press(keyCode: 126, characters: "\u{F700}") }

    /// Lets `Task`s started by the view run. `settle` alone can't: a test on the main actor is
    /// itself main queue work, which a nested run loop doesn't interleave with.
    func catchUp() async {
      await letTasksRun()
      settle(0.02)
      await letTasksRun()
    }

    /// Nothing of this process can be seen: a window on a display must be fully transparent.
    var nothingOnScreen: Bool {
      NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }.allSatisfy { window in
        NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }
      }
    }

    /// A view's frame from the top left of a sheet if one is up, as clicks expect.
    private func frame(of view: NSView) -> CGRect {
      view.convert(view.bounds, to: activeWindow.contentView ?? host)
    }
  }

  extension CGPoint {
    fileprivate func isBefore(_ other: CGPoint) -> Bool {
      abs(y - other.y) > 8 ? y < other.y : x < other.x
    }
  }

  /// Lets queued main-actor work run.
  @MainActor
  func letTasksRun() async {
    for _ in 0..<40 { await Task.yield() }
  }
#endif
