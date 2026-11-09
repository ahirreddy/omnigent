import AppKit
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// A surface in a borderless window that is never ordered in. Unlike `SurfaceHost`, nothing on
/// the user's screen changes.
@MainActor
struct NeverShownSurface {
  let connection: EchoTerminalConnection
  let controller: TerminalSurfaceController
  let window: NSWindow

  var view: TerminalSurfaceNSView { controller.view }

  init(
    connection: EchoTerminalConnection = EchoTerminalConnection(prompt: "$ ", banner: "ready"),
    width: CGFloat = 480, height: CGFloat = 240
  ) throws {
    _ = NSApplication.shared
    self.connection = connection
    controller = try TerminalSurfaceController(connection: connection)
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    unsafe controller.view.nextResponder = SilentResponder()
  }

  /// Whether the banner has reached the screen.
  func ready() async -> Bool {
    await eventually { controller.visibleText().contains("ready") }
  }

  /// Feeds `bytes` as remote output, then checks the terminal still renders new text.
  func survives(_ bytes: [UInt8], marker: String) async -> Bool {
    controller.feed(bytes)
    controller.render(.resetScreen)
    controller.feed(Array(marker.utf8))
    // libghostty's mailbox drains on a tick, which needs the main actor to come free.
    await Task.yield()
    return await eventually { controller.visibleText().contains(marker) }
  }
}

/// Ends a responder chain, which would otherwise beep at keys nobody took.
final class SilentResponder: NSResponder {
  override func keyDown(with event: NSEvent) {}
  override func keyUp(with event: NSEvent) {}
  override func noResponder(for eventSelector: Selector) {}
}

/// Renders a view through `NSHostingView` in a never-shown window.
@MainActor
enum OffscreenRender {
  /// Lays out and draws `view`; returns the bitmap's pixel count.
  @discardableResult
  static func draw(
    _ view: some View, width: CGFloat = 500, height: CGFloat = 400,
    settle: TimeInterval = 0.05
  ) -> Int {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.frame(width: width, height: height))
    let size = CGSize(width: width, height: height)
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    window.contentView = nil
    return bitmap.pixelsWide * bitmap.pixelsHigh
  }
}

/// A repeatable random sequence, so a failing fuzz run can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
}
