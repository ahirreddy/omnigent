import AppKit
import OmnigentGhosttyKit
import OmnigentViewTesting
import Synchronization
import Testing

@testable import OmnigentTerminalUI

/// Frames drawn by the surfaces this file creates.
private nonisolated let drawnFrames = Mutex(0)

/// libghostty calls this on its renderer thread for each step of a frame.
private nonisolated func countDrawnFrame(
  _: UnsafeMutableRawPointer?, _ event: ghostty_renderer_event_e
) {
  if event == GHOSTTY_RENDERER_EVENT_DRAW_FRAME_BEGIN { drawnFrames.withLock { $0 += 1 } }
}

/// A surface in a never-shown window whose drawn frames are counted.
@MainActor
private struct CountedSurface {
  let controller: TerminalSurfaceController
  let window: NSWindow

  init() throws {
    SystemSideEffects.install()
    _ = NSApplication.shared
    let connection = EchoTerminalConnection(prompt: "$ ", banner: "ready")
    controller = try unsafe TerminalSurfaceController(
      connection: connection, runtime: nil, newSurface: Self.newCountedSurface)
    let frame = CGRect(x: 0, y: 0, width: 480, height: 240)
    window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    controller.view.frame = frame
  }

  /// A surface from `config` that reports each frame it draws.
  private static func newCountedSurface(
    _ app: ghostty_app_t?, _ config: UnsafePointer<ghostty_surface_config_s>?
  ) -> ghostty_surface_t? {
    guard var counted = unsafe config?.pointee else { return nil }
    unsafe counted.renderer_event_cb = countDrawnFrame
    return unsafe ghostty_surface_new(app, &counted)
  }

  /// Frames drawn over `duration`, once the banner is on screen and its frames are done.
  func framesWhileIdle(for duration: Duration = .milliseconds(500)) async throws -> Int {
    let controller = controller
    #expect(await eventually { controller.visibleText().contains("ready") })
    try await Task.sleep(for: .milliseconds(300))
    let before = drawnFrames.withLock { $0 }
    try await Task.sleep(for: duration)
    return drawnFrames.withLock { $0 } - before
  }
}

/// A terminal draws every display refresh only while it has the keyboard; the others draw when
/// their content changes. Several open terminals otherwise each keep a display link running.
@MainActor
@Suite("A terminal without the keyboard draws only when its content changes", .serialized)
struct IdleSurfaceRenderingTests {
  @Test("a terminal that never had the keyboard draws no frames while idle")
  func neverFocusedSurfaceIsIdle() async throws {
    let surface = try CountedSurface()
    #expect(try await surface.framesWhileIdle() <= 2)
  }

  @Test("the terminal with the keyboard draws with the display, and stops when it loses it")
  func focusedSurfaceDrawsUntilItLosesFocus() async throws {
    let surface = try CountedSurface()
    surface.controller.setFocused(true)
    #expect(try await surface.framesWhileIdle() > 10)
    surface.controller.setFocused(false)
    #expect(try await surface.framesWhileIdle() <= 2)
  }
}
