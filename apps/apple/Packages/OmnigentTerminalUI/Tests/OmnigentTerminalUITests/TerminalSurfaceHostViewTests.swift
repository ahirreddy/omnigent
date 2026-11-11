import AppKit
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// What a host view reported as covered, in order.
private final class ReportedCover {
  var heights: [CGFloat] = []
}

/// A window's title bar and toolbar float over a full-size content view. A terminal's surface is
/// laid out, and sized, below them. The AppKit windows here are never ordered in.
@Suite("A terminal's surface under the window's title bar", .serialized)
struct TerminalSurfaceHostViewTests {
  private static let size = CGSize(width: 640, height: 480)
  private static let underTitleBar: NSWindow.StyleMask = [.titled, .fullSizeContentView]

  /// A window that is never ordered in, with `content` filling it, laid out.
  private func window(_ style: NSWindow.StyleMask, holding content: NSView) -> NSWindow {
    SystemSideEffects.install()
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: Self.size), styleMask: style, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = content
    content.layoutSubtreeIfNeeded()
    return window
  }

  /// The top of what the window's title bar leaves uncovered, in `view`'s coordinates.
  private func uncoveredTop(of window: NSWindow, in view: NSView) -> CGFloat {
    view.convert(window.contentLayoutRect, from: nil).maxY
  }

  @Test("Under a title bar the surface starts where the bar ends, and the terminal gets that size")
  func underTheTitleBar() async throws {
    SystemSideEffects.install()
    let connection = EchoTerminalConnection(prompt: "$ ", banner: "ready")
    let controller = try TerminalSurfaceController(connection: connection)
    let host = TerminalSurfaceHostView(surface: controller.view)
    let reported = ReportedCover()
    host.coveredTopChanged = { reported.heights.append($0) }
    let titled = window(Self.underTitleBar, holding: host)
    defer { titled.contentView = nil }

    let top = uncoveredTop(of: titled, in: host)
    let covered = (host.bounds.maxY - top).rounded()
    try #require(covered > 0, "a full-size content view reaches under the title bar")
    #expect(host.coveredTop == covered)
    #expect(
      controller.view.frame
        == CGRect(x: 0, y: 0, width: host.bounds.width, height: host.bounds.height - covered))
    #expect(await eventually { reported.heights.last == covered })

    // A surface alone at the uncovered size has the same grid: no row is under the bar.
    let alone = try NeverShownSurface(
      width: host.bounds.width, height: host.bounds.height - covered)
    let grid = try #require(controller.gridSize)
    #expect(grid == alone.controller.gridSize)
    #expect(connection.sizes.last == grid)
  }

  @Test("A terminal that starts below the title bar fills its place, with no gap above it")
  func belowTheTitleBar() throws {
    SystemSideEffects.install()
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    let host = TerminalSurfaceHostView(surface: controller.view)
    // A pane in the lower half of a window whose title bar floats over its content.
    let half = Self.size.height / 2
    let content = NSView(frame: CGRect(origin: .zero, size: Self.size))
    host.frame = CGRect(x: 0, y: 0, width: Self.size.width, height: half)
    content.addSubview(host)
    let titled = window(Self.underTitleBar, holding: content)
    defer { titled.contentView = nil }
    #expect(host.coveredTop == 0)
    #expect(controller.view.frame == host.bounds)

    // Moved to the window's top, the same view is covered and its surface gives way.
    host.setFrameOrigin(CGPoint(x: 0, y: content.bounds.maxY - half))
    content.layoutSubtreeIfNeeded()
    let covered = (host.bounds.maxY - uncoveredTop(of: titled, in: host)).rounded()
    try #require(covered > 0, "a full-size content view reaches under the title bar")
    #expect(host.coveredTop == covered)
    #expect(controller.view.frame.height == half - covered)
  }

  @Test("In a window with no title bar over its content the surface fills its host")
  func noTitleBar() throws {
    SystemSideEffects.install()
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    let host = TerminalSurfaceHostView(surface: controller.view)
    let plain = window([.borderless], holding: host)
    defer { plain.contentView = nil }
    #expect(host.coveredTop == 0)
    #expect(controller.view.frame == host.bounds)

    // A resize keeps it filled without waiting for the next layout.
    host.setFrameSize(CGSize(width: 500, height: 300))
    #expect(controller.view.frame.size == CGSize(width: 500, height: 300))
  }

  @Test("A toolbar that shows later moves the surface below it")
  func toolbarShownLater() throws {
    SystemSideEffects.install()
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    let host = TerminalSurfaceHostView(surface: controller.view)
    let titled = window(Self.underTitleBar, holding: host)
    defer { titled.contentView = nil }
    let before = host.coveredTop

    titled.toolbar = NSToolbar(identifier: "terminal-host-tests")
    titled.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    let covered = (host.bounds.maxY - uncoveredTop(of: titled, in: host)).rounded()
    #expect(covered >= before)
    #expect(host.coveredTop == covered)
    #expect(controller.view.frame.height == host.bounds.height - covered)
  }

  @Test("Out of a window a surface keeps its size, so a tab that shows again keeps its grid")
  func keepsItsSizeOutOfAWindow() throws {
    SystemSideEffects.install()
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    controller.view.setFrameSize(CGSize(width: 400, height: 200))
    let grid = controller.gridSize
    let host = TerminalSurfaceHostView(surface: controller.view)
    host.setFrameSize(Self.size)
    host.layoutSubtreeIfNeeded()
    #expect(controller.view.frame.size == CGSize(width: 400, height: 200))
    #expect(controller.gridSize == grid)
  }

  @Test("How much of a view the title bar covers")
  func coveredTop() {
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    let cover = TerminalSurfaceHostView.coveredTop(of:uncovered:)
    #expect(cover(bounds, CGRect(x: 0, y: 0, width: 600, height: 348)) == 52)
    #expect(cover(bounds, CGRect(x: 0, y: -200, width: 600, height: 600)) == 0)
    #expect(cover(bounds, CGRect(x: 0, y: -300, width: 600, height: 900)) == 0, "below the bar")
    #expect(cover(bounds, CGRect(x: 0, y: -900, width: 600, height: 500)) == 400, "all of it")
    #expect(cover(bounds, CGRect(x: 0, y: 0, width: 600, height: 399.8)) == 0, "under a point")
  }
}

/// The terminal page as SwiftUI lays it out, in a window ordered in off every display.
@Suite("A terminal page under the window's title bar", .serialized)
struct TerminalPageUnderTitleBarTests {
  @Test("Its surface and its find bar stay below the bar a scroll view beside it runs under")
  func pageUnderTheTitleBar() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    // Both ignore the safe area, as a page a container lays out under the title bar.
    let page = HStack(spacing: 0) {
      ScrollView { Color.clear.frame(height: 2_000) }
      SessionTerminalView(controller: surface.controller)
    }
    .ignoresSafeArea()
    let screen = OffscreenWindow(page, width: 800, height: 500)
    defer { screen.close() }
    let frame = screen.window.frame
    screen.window.contentView = nil
    screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
    screen.window.setFrame(frame, display: false)
    screen.window.contentView = screen.host
    screen.settle(0.3)

    let top = screen.host.convert(screen.host.bounds, to: nil).maxY
    let barBottom = screen.window.contentLayoutRect.maxY
    try #require(barBottom < top, "a full-size content view reaches under the title bar")
    let scroll = try #require(screen.allViews.compactMap { $0 as? NSScrollView }.first)
    #expect(scroll.convert(scroll.bounds, to: nil).maxY > barBottom, "the scroll view runs under")
    let view = surface.controller.view
    #expect(abs(view.convert(view.bounds, to: nil).maxY - barBottom) < 0.5)
    #expect(surface.connection.sizes.last == surface.controller.gridSize)

    surface.controller.startSearch()
    let covered = top - barBottom
    let findBarIsBelow = await eventually {
      let controls = screen.controlFrames
      return !controls.isEmpty && controls.allSatisfy { $0.minY >= covered }
    }
    #expect(findBarIsBelow, "the find bar's controls: \(screen.controlFrames)")
  }
}
