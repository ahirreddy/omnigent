import AppKit
import Foundation
import OWLProtocol
import OmnigentInput
import SwiftUI
import Testing

@testable import OmnigentWebLayer

/// The view that embeds a page, offscreen in a never-shown window.
@MainActor
@Suite("Web surface view", .serialized)
struct WebSurfaceViewTests {
  private struct Hosted {
    let fixture: ProtocolFixture
    let surface: WebSurfaceView
    let window: NSWindow
    let sink: SilentResponder
  }

  private func hosted() -> Hosted {
    let fixture = ProtocolFixture()
    let window = Offscreen.window()
    let surface = WebSurfaceView(webView: fixture.webView)
    window.contentView = surface
    let sink = SilentResponder()
    unsafe surface.nextResponder = sink
    return Hosted(fixture: fixture, surface: surface, window: window, sink: sink)
  }

  private func pasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ai.omnigent.tests.\(UUID().uuidString)"))
  }

  @Test func geometryReachesTheViewOnceInAWindow() {
    let fixture = ProtocolFixture()
    let surface = WebSurfaceView(webView: fixture.webView)
    #expect(surface.isFlipped && surface.acceptsFirstResponder)
    #expect(surface.acceptsFirstMouse(for: nil))
    surface.setFrameSize(CGSize(width: 10, height: 10))
    // Without a window the view reports itself hidden.
    #expect(!fixture.webView.isVisible)
    let window = Offscreen.window()
    window.contentView = surface
    surface.setFrameSize(CGSize(width: 200, height: 100))
    #expect(fixture.webView.size == CGSize(width: 200, height: 100))
    surface.viewDidChangeBackingProperties()
    surface.viewDidHide()
    surface.viewDidUnhide()
    surface.updateTrackingAreas()
    surface.updateTrackingAreas()
    #expect(surface.trackingAreas.count == 1)
    window.contentView = nil
    #expect(!fixture.webView.isVisible)
  }

  @Test func focusFollowsTheFirstResponder() {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    #expect(surface.becomeFirstResponder())
    #expect(fixture.webView.isFocused)
    #expect(surface.resignFirstResponder())
    #expect(!fixture.webView.isFocused)
    window.contentView = nil
  }

  @Test func mouseEventsReachThePage() throws {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    surface.mouseDown(with: try Offscreen.mouseEvent(.leftMouseDown, window: window))
    #expect(surface.lastMouseDown != nil)
    surface.mouseDragged(with: try Offscreen.mouseEvent(.leftMouseDragged, window: window))
    surface.mouseUp(with: try Offscreen.mouseEvent(.leftMouseUp, window: window))
    surface.mouseMoved(with: try Offscreen.mouseEvent(.mouseMoved, window: window))
    surface.rightMouseDown(with: try Offscreen.mouseEvent(.rightMouseDown, window: window))
    surface.rightMouseDragged(with: try Offscreen.mouseEvent(.rightMouseDragged, window: window))
    surface.rightMouseUp(with: try Offscreen.mouseEvent(.rightMouseUp, window: window))
    surface.otherMouseDown(with: try Offscreen.mouseEvent(.otherMouseDown, window: window))
    surface.otherMouseDragged(with: try Offscreen.mouseEvent(.otherMouseDragged, window: window))
    surface.otherMouseUp(with: try Offscreen.mouseEvent(.otherMouseUp, window: window))
    #expect(fixture.sent.filter { $0.kind == .inputMouse }.count == 10)
    #expect(fixture.webView.isFocused)
    window.contentView = nil
  }

  @Test func keysGoThroughTheComposerUnlessTheyAreCommands() throws {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    surface.flagsChanged(
      with: try Offscreen.keyEvent(.flagsChanged, characters: "", flags: .shift, window: window))
    surface.keyUp(with: try Offscreen.keyEvent(.keyUp, window: window))
    let command = try Offscreen.keyEvent(flags: .command, window: window)
    surface.keyDown(with: command)
    #expect(fixture.sent.contains { $0.kind == .inputKey })
    // A host before 1.1 gets the plain key.
    fixture.session.hostMinor = 0
    fixture.sent.removeAll()
    surface.keyDown(with: try Offscreen.keyEvent(window: window))
    #expect(fixture.sent.contains { $0.kind == .inputKey })
    window.contentView = nil
  }

  @Test func keyEquivalentsGoToThePageFirst() throws {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    let event = try Offscreen.keyEvent(flags: .command, window: window)
    #expect(!surface.performKeyEquivalent(with: event))
    window.makeFirstResponder(surface)
    #expect(surface.performKeyEquivalent(with: event))
    // The page gave it back: the app's menus and the responder chain see it.
    try fixture.receive(
      .keyUnhandled,
      WireEncoder().u64(.nativeKeyCode, 0).u64(.modifiers, InputModifiers.command.rawValue))
    #expect(host.sink.keyDowns == 1)
    window.contentView = nil
  }

  @Test func theTextInputClientReadsTheMirroredSelection() throws {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    try fixture.receive(
      .textSelectionChanged,
      WireEncoder().string(.text, "picked").i64(.rangeStart, 2).i64(.rangeEnd, 8))
    #expect(surface.selectedRange() == NSRange(location: 2, length: 6))
    let same = unsafe surface.attributedSubstring(
      forProposedRange: NSRange(location: 2, length: 6), actualRange: nil)
    #expect(same?.string == "picked")
    let other = unsafe surface.attributedSubstring(
      forProposedRange: NSRange(location: 0, length: 1), actualRange: nil)
    #expect(other == nil)
    #expect(surface.characterIndex(for: .zero) == NSNotFound)
    #expect(!surface.hasMarkedText())
    #expect(surface.markedRange().location == NSNotFound)
    #expect(!surface.validAttributesForMarkedText().isEmpty)
    surface.doCommand(by: #selector(NSResponder.moveLeft(_:)))
    surface.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(surface.hasMarkedText())
    #expect(fixture.last(.imeSetComposition) != nil)
    surface.unmarkText()
    surface.insertText("か", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(fixture.last(.imeCommitText) != nil)
    window.contentView = nil
  }

  @Test(
    "The candidate window's position takes any range and any rects",
    arguments: [
      NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: -1),
      NSRange(location: 0, length: 0), NSRange(location: Int.max - 1, length: 1),
    ])
  func candidatePosition(range: NSRange) throws {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    _ = unsafe surface.firstRect(forCharacterRange: range, actualRange: nil)
    try fixture.receive(
      .imeCompositionChanged, WireEncoder().string(.rects, "[[1,2,3,4],[5,6,7,8]]"))
    let rect = unsafe surface.firstRect(forCharacterRange: range, actualRange: nil)
    #expect(rect.width == 3 || rect.width == 7)
    try fixture.receive(
      .imeCompositionChanged, WireEncoder().string(.rects, "[[1e308,1e308,1e308,1e308]]"))
    _ = unsafe surface.firstRect(forCharacterRange: range, actualRange: nil)
    window.contentView = nil
    let detached = unsafe surface.firstRect(forCharacterRange: range, actualRange: nil)
    #expect(detached == .zero)
  }

  @Test func dropsIntoThePageBecomeDragMessages() throws {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    let board = pasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("text", forType: .string)
    board.setString("<b>x</b>", forType: .html)
    board.setString("https://a.example/", forType: .URL)
    let info = FakeDragInfo(pasteboard: board)
    #expect(surface.draggingEntered(info) == .copy)
    let enter = try #require(fixture.last(.dragEnter))
    let data = try JSONDecoder().decode(
      WebDragData.self, from: Data(try #require(enter.string(.dragData)).utf8))
    #expect(data.text == "text" && data.html == "<b>x</b>" && data.url == "https://a.example/")
    // Once the page answers, its answer is what AppKit sees.
    try fixture.receive(
      .dragCursor, WireEncoder().u64(.dragOperations, WebDragOperations.move.rawValue))
    #expect(surface.draggingUpdated(info) == .move)
    try fixture.receive(
      .dragCursor, WireEncoder().u64(.dragOperations, WebDragOperations.link.rawValue))
    #expect(surface.draggingUpdated(info).isEmpty)
    surface.draggingExited(info)
    surface.draggingExited(nil)
    #expect(surface.prepareForDragOperation(info))
    #expect(surface.performDragOperation(info))
    #expect(fixture.last(.dragDrop) != nil)
    window.contentView = nil
  }

  @Test func anOldHostRefusesDrops() {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    fixture.session.hostMinor = 0
    let board = pasteboard()
    defer { board.releaseGlobally() }
    let info = FakeDragInfo(pasteboard: board, operations: [.link])
    #expect(surface.draggingEntered(info).isEmpty)
    #expect(surface.draggingUpdated(info).isEmpty)
    #expect(!surface.prepareForDragOperation(info))
    window.contentView = nil
  }

  @Test func filesOnThePasteboardArePaths() {
    let board = pasteboard()
    defer { board.releaseGlobally() }
    board.clearContents()
    // swiftlint:disable:next legacy_objc_type
    board.writeObjects([URL(fileURLWithPath: "/tmp/a b.txt") as NSURL])
    #expect(WebSurfaceView.dragData(from: board).paths == ["/tmp/a b.txt"])
    let empty = pasteboard()
    defer { empty.releaseGlobally() }
    empty.clearContents()
    #expect(WebSurfaceView.dragData(from: empty) == WebDragData())
  }

  @Test func aDragOutOfThePageWritesOneKindOfContent() throws {
    let file = try #require(
      WebSurfaceView.pasteboardWriter(for: WebDragData(text: "t", paths: ["/tmp/a", "/tmp/b"]))
        as? NSPasteboardItem)
    #expect(file.string(forType: .fileURL) == "file:///tmp/a")
    #expect(file.string(forType: .string) == nil)
    let link = try #require(
      WebSurfaceView.pasteboardWriter(for: WebDragData(url: "https://a/")) as? NSPasteboardItem)
    #expect(link.string(forType: .URL) == "https://a/")
    #expect(link.string(forType: .string) == "https://a/")
    let full = try #require(
      WebSurfaceView.pasteboardWriter(for: WebDragData(text: "t", html: "h", url: "u"))
        as? NSPasteboardItem)
    #expect(full.string(forType: .string) == "t")
    #expect(full.string(forType: .html) == "h")
    let hostile = WebSurfaceView.pasteboardWriter(for: WebDragData(paths: ["", "\u{0}"]))
    #expect(hostile is NSPasteboardItem)
  }

  @Test func aDragWithoutAMouseDownEndsAtOnce() throws {
    let host = hosted()
    let (fixture, window) = (host.fixture, host.window)
    try fixture.receive(
      .startDrag, WireEncoder().string(.dragData, "{}").double(.X, 1).double(.Y, 2))
    let ended = try #require(fixture.last(.dragSourceEnded))
    #expect(ended.double(.X) == 1)
    #expect(ended.u64(.dragOperations) == 0)
    window.contentView = nil
  }

  @Test func everyCursorHasARect() {
    let fixture = ProtocolFixture()
    let surface = WebSurfaceView(webView: fixture.webView)
    let cursors: [WebCursor] = [
      .pointer, .hand, .iBeam, .crosshair, .wait, .help, .resizeLeftRight, .resizeUpDown,
      .notAllowed, .grab, .grabbing, .none,
    ]
    for cursor in cursors {
      fixture.webView.cursor = cursor
      surface.resetCursorRects()
    }
    #expect(fixture.webView.cursor == .none)
  }
}

@MainActor
@Suite("Web layer view", .serialized)
struct WebLayerViewTests {
  private static let statuses: [WebView.Status] = [
    .waitingForHost, .creating, .live, .closed,
    .unavailable(.hostExited(status: 9, reason: String(repeating: "W", count: 10_000))),
    .unavailable(.scriptFailed("\u{202E}مرحبا 👩‍👩‍👧‍👦\n\t\u{0}")),
  ]

  @Test func everyStatusDrawsAtAnySize() {
    for status in Self.statuses {
      let fixture = ProtocolFixture()
      fixture.webView.status = status
      let view = WebLayerView(webView: fixture.webView)
      let window = Offscreen.window()
      window.contentView = view
      for size in [
        CGSize(width: 240, height: 200), CGSize(width: 700, height: 500),
        CGSize(width: 1, height: 1),
      ] {
        view.setFrameSize(size)
        view.layout()
        #expect(Offscreen.draw(view) > 0)
      }
      view.focusPage()
      window.contentView = nil
    }
  }

  @Test func theOverlayFollowsTheStatus() async throws {
    let fixture = ProtocolFixture()
    fixture.webView.status = .waitingForHost
    let view = WebLayerView(webView: fixture.webView)
    fixture.webView.status = .live
    try await Task.sleep(for: .milliseconds(20))
    fixture.webView.status = .creating
    try await Task.sleep(for: .milliseconds(20))
    #expect(view.webView === fixture.webView)
  }

  @Test func theSwiftUIWrapperHostsTheView() {
    let fixture = ProtocolFixture()
    let host = NSHostingView(
      rootView: WebLayerContent(webView: fixture.webView).frame(width: 300, height: 200))
    let window = Offscreen.window()
    window.contentView = host
    #expect(Offscreen.draw(host) > 0)
    window.contentView = nil
  }
}
