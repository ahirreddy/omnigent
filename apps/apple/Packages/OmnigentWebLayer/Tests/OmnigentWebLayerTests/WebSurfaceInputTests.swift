import AppKit
import Foundation
import IOSurface
import OWLProtocol
import OmnigentInput
import Testing

@testable import OmnigentWebLayer

/// What the surface does with the pointer, keys and a page's drag, beyond the basics above.
@MainActor
@Suite("Web surface input", .serialized)
struct WebSurfaceInputTests {
  /// ⌘A, as the host returns a shortcut the page didn't take.
  private static let commandA = WireEncoder()
    .u64(.nativeKeyCode, 0).u64(.modifiers, InputModifiers.command.rawValue)
    .u64(.character, 97).u64(.unmodifiedCharacter, 97)

  private struct Hosted {
    let fixture: ProtocolFixture
    let surface: WebSurfaceView
    let window: NSWindow
    let sink = SilentResponder()
  }

  private func hosted(window: NSWindow = Offscreen.window()) -> Hosted {
    let fixture = ProtocolFixture()
    window.setFrameOrigin(CGPoint(x: -60_000, y: -60_000))
    let surface = WebSurfaceView(webView: fixture.webView)
    window.contentView = surface
    let host = Hosted(fixture: fixture, surface: surface, window: window)
    unsafe surface.nextResponder = host.sink
    fixture.sent.removeAll()
    return host
  }

  @Test("the pointer entering, leaving and scrolling reach the page")
  func pointer() throws {
    let host = hosted()
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
    let host = hosted()
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
    let host = hosted()
    let (fixture, window) = (host.fixture, host.window)
    window.setFrameOrigin(CGPoint(x: -50_000, y: -50_000))
    NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    #expect(fixture.sent.contains { $0.kind == .viewResize })
    window.contentView = nil
  }

  @Test("a page's changing cursor keeps being followed")
  func cursorFollows() async throws {
    let host = hosted()
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
    let host = hosted()
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

  @Test("a shortcut the page gave back goes to the window first, and doesn't return to the page")
  func unhandledShortcutGoesToTheWindow() throws {
    let window = ShortcutWindow()
    let host = hosted(window: window)
    let (fixture, surface) = (host.fixture, host.surface)
    window.shortcut = { event in
      surface.keyDown(with: event)
      surface.keyUp(with: event)
    }
    let event = try Offscreen.keyEvent(flags: .command, window: window)
    #expect(window.makeFirstResponder(surface))
    #expect(surface.performKeyEquivalent(with: event))
    fixture.sent.removeAll()
    try fixture.receive(.keyUnhandled, Self.commandA)
    #expect(window.shortcuts == 1)
    #expect(host.sink.keyDowns == 1)
    #expect(fixture.sent.isEmpty)
    window.contentView = nil
  }

  @Test("a shortcut the page gave back runs the app's menu item, and goes no further")
  func unhandledShortcutRunsTheMenu() throws {
    let host = hosted()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    let target = MenuActionRecorder()
    let item = NSMenuItem(
      title: "Act", action: #selector(MenuActionRecorder.act), keyEquivalent: "a")
    item.target = target
    let menu = NSMenu()
    menu.addItem(item)
    let previous = NSApp.mainMenu
    NSApp.mainMenu = menu
    defer { NSApp.mainMenu = previous }
    let event = try Offscreen.keyEvent(flags: .command, window: window)
    #expect(window.makeFirstResponder(surface))
    #expect(surface.performKeyEquivalent(with: event))
    try fixture.receive(.keyUnhandled, Self.commandA)
    #expect(target.count == 1)
    #expect(host.sink.keyDowns == 0)
    window.contentView = nil
  }

  @Test("hiding the page's popup gives its surface back to the host")
  func popupHidden() throws {
    let host = hosted()
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

/// A window that takes every key equivalent, as one with a matching SwiftUI shortcut does.
private final class ShortcutWindow: NSWindow {
  var shortcuts = 0
  var shortcut: (NSEvent) -> Void = { _ in }

  init() {
    super.init(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    shortcuts += 1
    shortcut(event)
    return true
  }
}

private final class MenuActionRecorder: NSObject {
  var count = 0
  @objc func act() { count += 1 }
}
