import AppKit
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// A terminal page as a tab shows it: a surface once it is ready, two text fields the user can
/// move into, and a sheet.
@MainActor
@Observable
private final class FocusPage {
  var surface: TerminalSurfaceController?
  var isShown = true
  var isActive = true
  var showsSheet = false
}

private struct FocusHost: View {
  @Bindable var page: FocusPage
  @State private var search = ""
  @State private var notes = ""

  var body: some View {
    VStack(spacing: 8) {
      TextField("Search", text: $search)
      TextField("Notes", text: $notes)
      Group {
        if let surface = page.surface {
          SessionTerminalView(controller: surface)
        } else {
          Text("Starting the terminal")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .terminalKeyboardFocus(page.surface, isShown: page.isShown, isActive: page.isActive)
    }
    .sheet(isPresented: $page.showsSheet) {
      Text("A sheet").frame(width: 200, height: 100)
    }
  }
}

@MainActor
@Suite("A terminal takes the keyboard as it comes on screen", .serialized)
struct TerminalKeyboardFocusTests {
  private typealias Screen = OffscreenWindow<FocusHost>

  private func screen(_ page: FocusPage) -> Screen {
    SystemSideEffects.install()
    return OffscreenWindow(FocusHost(page: page), width: 600, height: 400)
  }

  private func surface(_ connection: EchoTerminalConnection = EchoTerminalConnection())
    throws -> TerminalSurfaceController
  {
    SystemSideEffects.install()
    return try TerminalSurfaceController(connection: connection)
  }

  /// Runs the window and the view's tasks, which need the main actor free, for `seconds`.
  private func run(_ screen: Screen, _ seconds: Double = 0.1) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      screen.settle(0.005)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  /// Runs the window and its tasks until `condition` holds, or three seconds.
  private func settle(_ screen: Screen, until condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
      screen.settle(0.005)
      try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  /// The text fields, top to bottom.
  private func fields(_ screen: Screen) -> [NSTextField] {
    screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
      .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
  }

  /// The text field the window's field editor is editing, if any.
  private func editedField(_ screen: Screen) -> NSTextField? {
    (screen.window.firstResponder as? NSTextView)?.delegate as? NSTextField
  }

  @Test("a terminal shown in the focused pane takes the keyboard, and typing reaches it")
  func takesTheKeyboard() async throws {
    let connection = EchoTerminalConnection(prompt: "$ ", banner: "ready")
    let page = FocusPage()
    let controller = try surface(connection)
    page.surface = controller
    let screen = screen(page)
    defer { screen.close() }
    #expect(try await settle(screen) { screen.window.firstResponder === controller.view })
    #expect(try await settle(screen) { connection.state == .attached(readOnly: false) })
    try screen.type("a")
    #expect(try await settle(screen) { connection.received.last == 0x61 })
  }

  @Test("a terminal that becomes ready after it shows takes the keyboard then")
  func readyLater() async throws {
    let page = FocusPage()
    let screen = screen(page)
    defer { screen.close() }
    try await run(screen, 0.3)
    // The view that finds the window, under the whole page, takes no clicks from it.
    let hit = screen.host.hitTest(CGPoint(x: 300, y: 100))
    #expect(
      hit.map { "\(type(of: $0))".contains("ReaderView") } == false, "\(String(describing: hit))")
    let controller = try surface()
    page.surface = controller
    #expect(try await settle(screen) { screen.window.firstResponder === controller.view })
  }

  @Test("a text field the user moved into while the terminal started keeps the keyboard")
  func movedIntoAField() async throws {
    let page = FocusPage()
    let screen = screen(page)
    defer { screen.close() }
    try await run(screen)
    let search = try #require(fields(screen).first)
    try screen.click(search)
    #expect(editedField(screen) === search)
    let controller = try surface()
    page.surface = controller
    try await run(screen, 0.4)
    #expect(editedField(screen) === search)
  }

  @Test("the field that had the keyboard as the terminal showed gives it up; another keeps it")
  func fieldsBeforeAndAfter() async throws {
    let page = FocusPage()
    page.isShown = false
    let controller = try surface()
    page.surface = controller
    let screen = screen(page)
    defer { screen.close() }
    try await run(screen)
    let shown = fields(screen)
    try #require(shown.count == 2)
    #expect(screen.window.makeFirstResponder(shown[0]))
    page.isShown = true
    #expect(try await settle(screen) { screen.window.firstResponder === controller.view })

    page.isShown = false
    try await run(screen)
    #expect(screen.window.makeFirstResponder(shown[0]))
    page.isShown = true
    try await run(screen, 0.02)
    // The user moves inside the 100 ms the terminal waits for.
    #expect(screen.window.makeFirstResponder(shown[1]))
    try await run(screen, 0.4)
    #expect(editedField(screen) === shown[1])
  }

  @Test("a hidden terminal gives the keyboard up; one in the other pane neither takes nor drops it")
  func hiddenAndOtherPane() async throws {
    let page = FocusPage()
    let controller = try surface()
    page.surface = controller
    let screen = screen(page)
    defer { screen.close() }
    #expect(try await settle(screen) { screen.window.firstResponder === controller.view })

    page.isActive = false
    try await run(screen, 0.3)
    #expect(screen.window.firstResponder === controller.view, "another pane's focus is a click")
    page.isShown = false
    try await run(screen)
    #expect(screen.window.firstResponder === screen.window)

    page.isShown = true
    try await run(screen, 0.4)
    #expect(screen.window.firstResponder === screen.window, "shown, but not in the focused pane")
    page.isActive = true
    #expect(try await settle(screen) { screen.window.firstResponder === controller.view })
  }

  @Test("a terminal hidden before its wait ends never takes the keyboard")
  func hiddenDuringTheWait() async throws {
    let page = FocusPage()
    let screen = screen(page)
    defer { screen.close() }
    try await run(screen)
    let controller = try surface()
    page.surface = controller
    try await run(screen, 0.02)
    page.isShown = false
    try await run(screen, 0.4)
    #expect(screen.window.firstResponder === screen.window)
  }

  @Test("a sheet keeps the keyboard from a terminal that becomes ready under it")
  func underASheet() async throws {
    let page = FocusPage()
    let screen = screen(page)
    defer { screen.close() }
    page.showsSheet = true
    #expect(try await settle(screen) { screen.window.attachedSheet != nil })
    let controller = try surface()
    page.surface = controller
    try await run(screen, 0.4)
    #expect(screen.window.firstResponder === screen.window)
  }

  @Test("plain keys moving through a list keep its focus; shortcuts and clicks do not")
  func listKeys() throws {
    let arrow = try Events.key(characters: "\u{F701}", keyCode: 0x7D)
    let controlTab = try Events.key(characters: "\t", keyCode: 0x30, flags: .control)
    let nextTab = try Events.key(characters: "]", keyCode: 0x1E, flags: [.shift, .command])
    let arrowUp = try Events.key(.keyUp, characters: "\u{F701}", keyCode: 0x7D)
    #expect(TerminalFocusRequest.movesThroughList(arrow))
    #expect(!TerminalFocusRequest.movesThroughList(controlTab))
    #expect(!TerminalFocusRequest.movesThroughList(nextTab))
    #expect(!TerminalFocusRequest.movesThroughList(arrowUp))
    #expect(!TerminalFocusRequest.movesThroughList(try Events.mouse(.leftMouseUp)))
    #expect(!TerminalFocusRequest.movesThroughList(nil))

    let request = TerminalFocusRequest()
    request.begin(after: arrow)
    #expect(!request.isPending)
    request.begin(after: controlTab)
    #expect(request.isPending)
    #expect(!request.complete(NSView()), "a view in no window waits")
    #expect(request.isPending)
    request.cancel()
    #expect(!request.isPending)
  }
}
