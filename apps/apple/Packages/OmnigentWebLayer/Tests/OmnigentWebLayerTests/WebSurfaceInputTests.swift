import AppKit
import Foundation
import IOSurface
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// A surface that records the drag AppKit would start instead of taking over the pointer.
private final class RecordingDragSurface: WebSurfaceView {
  var startedItems: [NSDraggingItem] = []

  override func beginDraggingSession(
    with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource
  ) -> NSDraggingSession {
    startedItems = items
    return NSDraggingSession()
  }
}

/// What the surface does with the pointer, keys and a page's drag, beyond the basics above.
@MainActor
@Suite("Web surface input", .serialized)
struct WebSurfaceInputTests {
  @Test("the pointer entering, leaving and scrolling reach the page")
  func pointer() throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    surface.mouseEntered(with: try Offscreen.mouseEvent(.mouseMoved, window: window))
    surface.mouseExited(with: try Offscreen.mouseEvent(.mouseMoved, window: window))
    #expect(fixture.sent.filter { $0.kind == .inputMouse }.count == 2)
    let scroll = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 0, wheel3: 0)
    )
    surface.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
    #expect(fixture.sent.count >= 3)
    window.contentView = nil
  }

  @Test("a plain key on a 1.1 host goes through the composer to the page")
  func composedKey() throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    surface.keyDown(with: try Offscreen.keyEvent(window: window))
    surface.forwardKeyEvent(try Offscreen.keyEvent(window: window))
    #expect(fixture.sent.contains { $0.kind == .inputKey })
    surface.cancelComposition()
    #expect(fixture.sent.contains { $0.kind == .imeCancelComposition })
    window.contentView = nil
  }

  @Test("moving the window tells the page where it is now")
  func windowMoved() {
    let host = HostedSurface()
    let (fixture, window) = (host.fixture, host.window)
    window.setFrameOrigin(CGPoint(x: -50_000, y: -50_000))
    NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    #expect(fixture.sent.contains { $0.kind == .viewResize })
    window.contentView = nil
  }

  @Test("a page's changing cursor keeps being followed")
  func cursorFollows() async throws {
    let host = HostedSurface()
    let (fixture, window) = (host.fixture, host.window)
    try fixture.receive(.cursorChanged, WireEncoder().u64(.cursor, 1))
    for _ in 0..<20 { await Task.yield() }
    try fixture.receive(.cursorChanged, WireEncoder().u64(.cursor, 2))
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.webView.cursor == WebCursor(wire: 2))
    window.contentView = nil
  }

  @Test("a page's drag carries its image or a placeholder, and reports where it ended")
  func pageDrag() throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    let plain = WebDragStart(
      data: WebDragData(text: "t"), operations: .copy, location: .zero, image: Data([0xFF]))
    let item = WebSurfaceView.draggingItem(for: plain)
    #expect(item.draggingFrame.size.width > 0)

    surface.pageDrag = plain
    #expect(surface.pageDragOperations == .copy)
    surface.pageDragEnded(at: window.convertPoint(toScreen: CGPoint(x: 5, y: 5)), operation: .copy)
    #expect(surface.pageDrag == nil)
    #expect(surface.pageDragOperations.isEmpty)
    let ended = try #require(fixture.last(.dragSourceEnded))
    #expect(ended.u64(.dragOperations) != 0)
    window.contentView = nil
  }

  @Test("a page's drag starts from the last mouse-down, and AppKit's callbacks reach the page")
  func pageDragStarts() throws {
    let fixture = ProtocolFixture()
    let surface = RecordingDragSurface(webView: fixture.webView)
    let start = WebDragStart(
      data: WebDragData(text: "t"), operations: .copy, location: .zero, image: nil)
    surface.lastMouseDown = try Offscreen.mouseEvent(.leftMouseDown)
    surface.beginPageDrag(start)
    #expect(surface.startedItems.count == 1)
    #expect(surface.pageDrag != nil)

    let session = NSDraggingSession()
    #expect(surface.draggingSession(session, sourceOperationMaskFor: .outsideApplication) == .copy)
    fixture.sent.removeAll()
    surface.draggingSession(session, endedAt: .zero, operation: .copy)
    #expect(surface.pageDrag == nil)
    #expect(fixture.last(.dragSourceEnded) != nil)
  }

  @Test("the page's cursor shows at once only while the pointer is over the view")
  func cursorUnderThePointer() throws {
    let host = HostedSurface()
    let (fixture, surface) = (host.fixture, host.surface)
    try fixture.receive(.cursorChanged, WireEncoder().u64(.cursor, 1))
    NSCursor.arrow.set()
    surface.updateCursor(pointerAt: CGPoint(x: -1, y: -1))
    #expect(NSCursor.current == NSCursor.arrow)
    surface.updateCursor(pointerAt: CGPoint(x: 1, y: 1))
    #expect(NSCursor.current != NSCursor.arrow)
    NSCursor.arrow.set()
    host.window.contentView = nil
  }

  @Test("hiding the page's popup gives its surface back to the host")
  func popupHidden() throws {
    let host = HostedSurface()
    let (fixture, window) = (host.fixture, host.window)
    let surface = try #require(
      IOSurface(properties: [.width: 8, .height: 8, .bytesPerElement: 4, .pixelFormat: 0x4247_5241])
    )
    let frame = SurfaceFrame(
      surface: surface, surfaceID: 42, layer: .popup, pixelSize: CGSize(width: 8, height: 8),
      scale: 1, popupOrigin: .zero, popupVisible: true)
    _ = fixture.webView.layerHost.present(frame)
    try fixture.receive(.popupVisibility, WireEncoder().bool(.visible, false))
    #expect(fixture.sent.contains { $0.kind == .frameAck })
    window.contentView = nil
  }
}
