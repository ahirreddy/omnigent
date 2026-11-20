#if os(macOS)
  import AppKit
  import CoreGraphics
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// Annotate and Draw on a tab: the toolbar's toggles, the overlay, and the model's wiring to
  /// its page and the app's sender.
  @MainActor
  @Suite("Design tools on a tab, off screen", .serialized)
  struct DesignToolsViewTests {
    /// A tab whose environment takes design requests into `sent`.
    private func fixture(sent: @escaping (BrowserDesignRequest) -> Void) throws -> TabFixture {
      let fixture = try TabFixture()
      fixture.environment.designRequestSender = { request, _ in sent(request) }
      return fixture
    }

    @Test("the toolbar offers Annotate and Draw only when the app takes their requests")
    func toolbarToggles() throws {
      let plain = try TabFixture()
      #expect(!plain.model.offersDesignTools)
      let fixture = try fixture { _ in }
      #expect(fixture.model.offersDesignTools && !fixture.model.designToolsAreIsolated)
      let toolbar = { (fixture: TabFixture) in
        OffscreenWindow(
          BrowserTabToolbar(
            model: fixture.model, environment: fixture.environment, sheet: .constant(nil)),
          width: 900, height: 60)
      }
      let without = toolbar(plain)
      defer { without.close() }
      let screen = toolbar(fixture)
      defer { screen.close() }
      #expect(screen.buttons.count == without.buttons.count + 2)
      // Back, Forward, Reload and the address field's star, then Annotate and Draw.
      try screen.clickButton(at: 4)
      #expect(fixture.model.designTools.tool == .annotate)
      try screen.clickButton(at: 5)
      #expect(fixture.model.designTools.tool == .draw)
      try screen.clickButton(at: 5)
      #expect(fixture.model.designTools.tool == nil)
    }

    @Test("the model's tools pick through the tab's page and send through the environment")
    func modelWiring() async throws {
      var sent: [BrowserDesignRequest] = []
      let fixture = try fixture { sent.append($0) }
      let tab = try fixture.tab
      tab.scriptResult = DesignPickerTests.answer(viewport: #"{"width":100,"height":100}"#)
      tab.snapshotPNG = try BrowserDesignCapture.pngData(solidImage(width: 100, height: 100))
      let tools = fixture.model.designTools
      tools.open(.annotate)
      await tools.pick(at: CGPoint(x: 0.5, y: 0.5))
      #expect(tab.scripts.last?.contains("at(0.5 * width, 0.5 * height)") == true)
      tools.request = "Say hello"
      await tools.sendAnnotation()
      let request = try #require(sent.first)
      #expect(request.pageURL == fixture.model.url && request.screenshotPNG != nil)
    }

    @Test("the overlay shows the open tool's layer and closes it when the page changes")
    func overlay() throws {
      let fixture = try fixture { _ in }
      let tools = fixture.model.designTools
      let screen = OffscreenWindow(
        BrowserDesignOverlay(model: fixture.model), width: 600, height: 400)
      defer { screen.close() }
      #expect(!screen.allViews.contains { $0 is BrowserDesignInputView })
      tools.open(.draw)
      screen.settle()
      #expect(screen.allViews.contains { $0 is BrowserDesignInputView })
      #expect(screen.fields.contains { $0.placeholderString == "Add a note for the agent" })
      try fixture.tab.load(testURL("https://a.example/next"))
      screen.settle()
      #expect(tools.tool == nil && tools.notice?.message == BrowserDesignTools.pageChangedNotice)
    }

    @Test("with no tool open the page takes its clicks, notice or not; an open tool takes them")
    func clicksReachThePageOnlyWithoutATool() throws {
      let fixture = try fixture { _ in }
      let tools = fixture.model.designTools
      let page = ClickCountingView()
      let screen = OffscreenWindow(
        ZStack {
          ClickTarget(view: page)
          BrowserDesignOverlay(model: fixture.model)
        }, width: 600, height: 400)
      defer { screen.close() }
      try screen.click(CGPoint(x: 300, y: 200))
      tools.show("Sent to agent.", isError: false)
      screen.settle()
      try screen.click(CGPoint(x: 300, y: 200))
      #expect(page.clicks == 2)
      tools.open(.draw)
      screen.settle()
      try screen.click(CGPoint(x: 300, y: 300))
      #expect(page.clicks == 2)
    }

    @Test("Draw's text marks: typed where clicked; a click elsewhere keeps them and starts anew")
    func textMarks() throws {
      let fixture = try fixture { _ in }
      let tools = fixture.model.designTools
      let screen = OffscreenWindow(
        BrowserDesignOverlay(model: fixture.model), width: 600, height: 400)
      defer { screen.close() }
      tools.open(.draw)
      tools.shape = .text
      screen.settle()
      try screen.click(CGPoint(x: 100, y: 200))
      screen.settle()
      #expect(screen.fields.contains { $0.placeholderString == "Type, then Return" })
      try screen.type("One")
      try screen.click(CGPoint(x: 300, y: 300))
      screen.settle()
      #expect(tools.marks.map(\.text) == ["One"])
      #expect(tools.marks.first?.points == [CGPoint(x: 100, y: 200)])
      try screen.type("Two")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(tools.marks.map(\.text) == ["One", "Two"])
      #expect(!screen.fields.contains { $0.placeholderString == "Type, then Return" })
    }

    @Test("the input layer reports the pointer from the top left and takes Escape")
    func inputLayer() throws {
      var events: [String] = []
      let view = BrowserDesignInputView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
      view.handlers = BrowserDesignInputHandlers(
        move: { events.append("move \(Int($0.x)),\(Int($0.y))") },
        press: { events.append("down \(Int($0.x)),\(Int($0.y))") },
        escape: { events.append("escape") })
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
        backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.contentView = view
      defer { window.close() }
      #expect(window.firstResponder === view)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .leftMouseDown, location: CGPoint(x: 20, y: 90), modifierFlags: [],
          timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
          clickCount: 1, pressure: 1))
      view.mouseDown(with: event)
      view.cancelOperation(nil)
      #expect(events == ["down 20,10", "escape"])
      #expect(view.menu(for: event) == nil)
    }
  }

  /// A stand-in for the page's view that counts the clicks reaching it.
  final class ClickCountingView: NSView {
    private(set) var clicks = 0

    override func mouseDown(with event: NSEvent) { clicks += 1 }
  }

  /// Shows a given view, so the test keeps hold of it.
  struct ClickTarget: NSViewRepresentable {
    let view: ClickCountingView

    func makeNSView(context: Context) -> ClickCountingView { view }

    func updateNSView(_ nsView: ClickCountingView, context: Context) {}
  }
#endif
