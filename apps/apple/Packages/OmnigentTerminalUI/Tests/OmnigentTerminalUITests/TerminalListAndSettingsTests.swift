import AppKit
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// What the list asked its owner to do.
@MainActor
private final class ListActions {
  var created: [String] = []
  var closed: [String] = []
  var selection: String?
}

extension OffscreenWindow {
  /// The points of the list's rows, top to bottom.
  fileprivate var rowPoints: [CGPoint] {
    allViews.compactMap { $0 as? NSTableRowView }
      .map { $0.convert($0.bounds, to: host) }
      .sorted { $0.minY < $1.minY }
      .map { CGPoint(x: $0.midX, y: $0.midY) }
  }

  /// A popup button's menu, filled as for opening it but not opened.
  fileprivate func popupMenu(at index: Int) throws -> NSMenu {
    let popups = allViews.compactMap { $0 as? NSPopUpButton }
      .sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
    let menu = try #require(popups[index].menu)
    let willShow = Selector(("popUpButtonCell:willShowMenu:"))
    if let delegate = menu.delegate as? NSObject, delegate.responds(to: willShow) {
      _ = unsafe delegate.perform(willShow, with: popups[index].cell, with: menu)
    }
    return menu
  }

  /// Where SwiftUI's own buttons are drawn, which `controlFrames` misses over a platform view.
  fileprivate var drawnButtons: [CGRect] {
    allViews.filter { String(describing: Swift.type(of: $0)) == "_FocusRingView" }
      .map { $0.convert($0.bounds, to: host) }
      .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
  }

  /// The titles of the menu items that have one.
  fileprivate func titles(of menu: NSMenu) -> [String] {
    menu.items.map(\.title).filter { !$0.isEmpty }
  }
}

@MainActor
private func listScreen(
  items: [TerminalListItem], shellChoices: [String] = ["zsh", "bash"], canEdit: Bool = true,
  errorMessage: String? = nil, actions: ListActions = ListActions()
) -> OffscreenWindow<some View> {
  SystemSideEffects.install()
  SystemSideEffects.reset()
  let selection = Binding(get: { actions.selection }, set: { actions.selection = $0 })
  let screen = OffscreenWindow(
    NavigationStack {
      TerminalListView(
        items: items, shellChoices: shellChoices, canEdit: canEdit, errorMessage: errorMessage,
        selection: selection, onCreate: { actions.created.append($0) },
        onClose: { actions.closed.append($0) })
    }, width: 500, height: 400)
  screen.settle()
  return screen
}

private let shell = TerminalListItem(
  id: "terminal_zsh", title: "zsh · one", status: .active, isAgentTerminal: false)
private let agent = TerminalListItem(
  id: "terminal_agent", title: "agent · two", status: .idle, isAgentTerminal: true)

@Suite("The terminal list", .serialized)
struct TerminalListTests {
  @Test("rows and the last error show; an empty list says so")
  func rowsAndEmpty() throws {
    let empty = listScreen(items: [], errorMessage: "could not load")
    defer { empty.close() }
    #expect(try empty.shows("No terminals yet."))
    #expect(try empty.shows("could not load"))
    let full = listScreen(items: [shell, agent])
    defer { full.close() }
    #expect(try full.shows("zsh · one"))
    #expect(try full.shows("agent · two"))
    #expect(try !full.shows("No terminals yet."))
  }

  @Test("closing a shell asks first, and only Close Terminal closes it")
  func closeAsksFirst() throws {
    let actions = ListActions()
    let screen = listScreen(items: [shell], actions: actions)
    defer {
      screen.close()
      SystemSideEffects.answer()
    }
    let menu = try #require(try screen.contextMenu(at: screen.rowPoints[0]))

    SystemSideEffects.answer(alert: .alertSecondButtonReturn)
    try screen.choose("Close Terminal", in: menu)
    screen.settle()
    #expect(SystemSideEffects.record.alertMessages.count == 1)
    #expect(actions.closed.isEmpty)

    SystemSideEffects.answer()
    try screen.choose("Close Terminal", in: menu)
    screen.settle()
    #expect(SystemSideEffects.record.alertMessages.count == 2)
    #expect(actions.closed == ["terminal_zsh"])
  }

  @Test("an agent's terminal can't be closed from the list, and read-only access can't close")
  func nothingToClose() throws {
    for (item, canEdit) in [(agent, true), (shell, false)] {
      let screen = listScreen(items: [item], canEdit: canEdit)
      defer { screen.close() }
      let menu = try screen.contextMenu(at: screen.rowPoints[0])
      #expect(menu?.items.contains { $0.title == "Close Terminal" } != true, "\(item.title)")
    }
  }

  @Test("New Terminal offers the declared shells and launches the chosen one")
  func newTerminalMenu() throws {
    SystemSideEffects.install()
    var created: [String] = []
    let screen = OffscreenWindow(
      NewTerminalMenu(shellChoices: ["zsh", "bash"]) { created.append($0) }, width: 200, height: 60)
    defer { screen.close() }
    screen.settle()
    let menu = try screen.popupMenu(at: 0)
    #expect(screen.titles(of: menu).suffix(2) == ["zsh", "bash"])
    try screen.choose("bash", in: menu)
    #expect(created == ["bash"])
  }
}

@Suite("Terminal settings", .serialized)
struct TerminalSettingsTests {
  /// Puts the shared runtime and the stored settings back after a test changes them.
  private func withRestoredSettings(_ body: () throws -> Void) throws {
    let runtime = try GhosttyRuntime.shared()
    let appearance = runtime.appearance
    let keys = [
      TerminalPreferences.fontSizeKey, TerminalPreferences.fontFamilyKey,
      TerminalPreferences.scrollbackKey, TerminalPreferences.optionAsAltKey,
      TerminalPreferences.cursorBlinkKey, TerminalClipboardPolicy.key,
    ]
    defer {
      do {
        try runtime.update(appearance: appearance)
      } catch {
        Issue.record("restoring the terminal's appearance failed: \(error)")
      }
      for key in keys {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    try body()
  }

  @Test("each control changes the running terminals and is kept for the next launch")
  func controls() throws {
    try withRestoredSettings {
      SystemSideEffects.install()
      let runtime = try GhosttyRuntime.shared()
      let defaults = UserDefaults.standard
      let screen = OffscreenWindow(TerminalSettingsView(), width: 600, height: 700)
      defer { screen.close() }
      screen.settle(0.3)
      let startingSize = runtime.appearance.fontSize

      // The stepper's upper half makes the font bigger.
      let stepper = try #require(screen.allViews.first { $0 is NSStepper })
      let stepperFrame = stepper.convert(stepper.bounds, to: screen.host)
      try screen.click(CGPoint(x: stepperFrame.midX, y: stepperFrame.minY + 6))
      screen.settle()
      #expect(runtime.appearance.fontSize == startingSize + 1)
      #expect(defaults.double(forKey: TerminalPreferences.fontSizeKey) == startingSize + 1)
      #expect(try screen.shows("\(Int(startingSize) + 1) pt"))

      // The family menu lists fonts after the system choice, and returning to it forgets the font.
      let families = try screen.popupMenu(at: 0)
      let family = try #require(screen.titles(of: families).first { !$0.hasPrefix("System") })
      try screen.choose(family, in: families)
      screen.settle()
      #expect(runtime.appearance.fontFamily == family)
      #expect(defaults.string(forKey: TerminalPreferences.fontFamilyKey) == family)
      let system = try #require(screen.titles(of: families).first { $0.hasPrefix("System") })
      try screen.choose(system, in: try screen.popupMenu(at: 0))
      screen.settle()
      #expect(runtime.appearance.fontFamily == nil)
      #expect(defaults.object(forKey: TerminalPreferences.fontFamilyKey) == nil)

      let scrollback = try #require(
        TerminalScrollback.allCases.first { $0 != runtime.appearance.scrollback })
      try screen.choose(scrollback.label, in: try screen.popupMenu(at: 1))
      screen.settle()
      #expect(runtime.appearance.scrollback == scrollback)
      #expect(defaults.integer(forKey: TerminalPreferences.scrollbackKey) == scrollback.rawValue)

      let switches = screen.controlFrames.filter { $0.height < 20 }
      let optionAsAlt = runtime.appearance.optionAsAlt
      try screen.click(CGPoint(x: switches[0].midX, y: switches[0].midY))
      screen.settle()
      #expect(runtime.appearance.optionAsAlt != optionAsAlt)
      #expect(defaults.bool(forKey: TerminalPreferences.optionAsAltKey) != optionAsAlt)
      let blink = runtime.appearance.cursorBlink
      try screen.click(CGPoint(x: switches[1].midX, y: switches[1].midY))
      screen.settle()
      #expect(runtime.appearance.cursorBlink != blink)
      #expect(defaults.bool(forKey: TerminalPreferences.cursorBlinkKey) != blink)

      try screen.choose(
        TerminalClipboardPolicy.block.title, in: try screen.popupMenu(at: 2))
      screen.settle()
      #expect(TerminalClipboardPolicy.current() == .block)
      #expect(try screen.shows(TerminalClipboardPolicy.block.title))
    }
  }
}

@Suite("The attached terminal's overlays", .serialized)
struct AttachedTerminalOverlayTests {
  private func attached(_ surface: NeverShownSurface) -> OffscreenWindow<SessionTerminalView> {
    let screen = OffscreenWindow(
      SessionTerminalView(controller: surface.controller), width: 600, height: 400)
    screen.settle(0.2)
    return screen
  }

  @Test("a program that exits shows the card over its last screen, and Reattach starts it again")
  func deadTerminalCard() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let screen = attached(surface)
    defer { screen.close() }
    #expect(try !screen.shows("Terminal ended"))
    surface.connection.simulateExit()
    #expect(await eventually { surface.controller.state != .attached(readOnly: false) })
    screen.settle()
    #expect(try screen.shows("Terminal ended"))
    let reattach = try #require(screen.drawnButtons.first)
    try screen.click(CGPoint(x: reattach.midX, y: reattach.midY))
    #expect(await eventually { surface.controller.state == .attached(readOnly: false) })
    screen.settle()
    #expect(try !screen.shows("Terminal ended"))
  }

  @Test("on a read-only terminal the badge leaves the banners' buttons clickable")
  func readOnlyBanners() async throws {
    let surface = try NeverShownSurface(
      connection: EchoTerminalConnection(prompt: "$ ", banner: "ready", readOnly: true))
    #expect(await surface.ready())
    SystemSideEffects.reset()
    let screen = attached(surface)
    defer { screen.close() }
    surface.controller.report("something broke")
    screen.settle()
    #expect(try screen.shows("something broke"))
    #expect(try screen.shows("Read-only"))
    let dismiss = try #require(screen.controlFrames.first)
    try screen.click(CGPoint(x: dismiss.midX, y: dismiss.midY))
    #expect(surface.controller.lastError == nil)
    #expect(try !screen.shows("something broke"))

    surface.controller.remoteCopied("copied", policy: .ask)
    screen.settle()
    #expect(try screen.shows("The terminal copied 6 characters."))
    screen.window.recalculateKeyViewLoop()
    let copy = try #require(screen.drawnButtons.first)
    try screen.click(CGPoint(x: copy.midX, y: copy.midY))
    #expect(surface.controller.pendingClipboard == nil)
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "copied")
  }

  @Test("Find opens its bar over the terminal, and closing it takes the bar away")
  func findOverTheTerminal() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let screen = attached(surface)
    defer { screen.close() }
    #expect(try !screen.shows("Close find"))
    surface.controller.startSearch()
    screen.settle()
    #expect(try screen.shows("Close find"))
    surface.controller.endSearch()
    screen.settle()
    #expect(try !screen.shows("Close find"))
  }

  @Test("a view that makes its own controller shows the terminal it makes")
  func ownController() async throws {
    SystemSideEffects.install()
    let connection = EchoTerminalConnection(prompt: "$ ", banner: "ready")
    let screen = OffscreenWindow(
      SessionTerminalView(connection: connection), width: 600, height: 400)
    defer { screen.close() }
    screen.settle(0.2)
    #expect(await eventually { connection.state == .attached(readOnly: false) })
    screen.settle()
    #expect(screen.allViews.contains { $0 is TerminalSurfaceNSView })
  }
}

@Suite("The surface's right click", .serialized)
struct SurfaceContextMenuTests {
  @Test("the edit menu's Copy needs a selection and its Paste needs something to paste")
  func editMenu() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    SystemSideEffects.reset()
    let menu = try #require(surface.view.menu(for: try Events.mouse(.rightMouseDown)))
    #expect(menu.items.map(\.title) == ["Copy", "Paste", "", "Select All", "Find…"])
    #expect(!surface.view.validateMenuItem(menu.items[0]))
    #expect(!surface.view.validateMenuItem(menu.items[1]))
    #expect(surface.view.validateMenuItem(menu.items[3]))
    SystemSideEffects.pasteboard.setString("x", forType: .string)
    #expect(surface.view.validateMenuItem(menu.items[1]))
    surface.controller.selectAll()
    #expect(surface.view.validateMenuItem(menu.items[0]))
  }
}
