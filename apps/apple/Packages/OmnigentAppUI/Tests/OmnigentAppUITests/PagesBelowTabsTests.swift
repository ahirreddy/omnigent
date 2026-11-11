import AppKit
import Foundation
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// The window's tabs float over its content in the title bar, and no page is drawn under them:
/// a chat's transcript and a terminal's surface both start where the tabs end.
@MainActor
@Suite("Pages below the window's tabs", .serialized, .timeLimit(.minutes(1)))
struct PagesBelowTabsTests {
  private typealias Screen = OffscreenWindow<AppWindowRoot>

  /// Narrower than any sidebar: what is further right is in the detail.
  private let sidebarEdge: CGFloat = 200

  private func frameInWindow(_ view: NSView) -> CGRect {
    view.convert(view.bounds, to: nil)
  }

  /// The bottom of the title bar and toolbar, in window coordinates (the origin at the bottom).
  private func tabsBottom(_ screen: Screen) throws -> CGFloat {
    let bottom = screen.window.contentLayoutRect.maxY
    let top = screen.host.convert(screen.host.bounds, to: nil).maxY
    try #require(bottom < top, "the toolbar floats over the top of the content")
    return bottom
  }

  /// The scroll views drawn in the detail, the transcript's among them.
  private func detailScrollViews(_ screen: Screen) -> [NSScrollView] {
    screen.drawnViews.compactMap { $0 as? NSScrollView }.filter {
      frameInWindow($0).minX >= sidebarEdge && $0.frame.height > 100
    }
  }

  private func terminalSurface(_ screen: Screen) -> NSView? {
    screen.drawnViews.first { String(describing: type(of: $0)) == "TerminalSurfaceNSView" }
  }

  @Test("A chat's transcript starts where the tabs end, and so does a terminal tab's surface")
  func chatAndTerminal() async throws {
    let session = try await connectedDemo()
    let screen = try await titledWindow(
      session, selection: WindowSelection(.session("demo-design")))
    defer { screen.close() }
    let bottom = try tabsBottom(screen)

    try await settle(screen, until: "the chat's transcript") {
      !detailScrollViews(screen).isEmpty
    }
    let tops = detailScrollViews(screen).map { frameInWindow($0).maxY }
    #expect(tops.allSatisfy { $0 <= bottom + 0.5 }, "no scroll view under the tabs: \(tops)")
    #expect(tops.contains { abs($0 - bottom) < 0.5 }, "the transcript reaches the tabs: \(tops)")

    session.tabs.current?.open(.terminal(sessionID: "demo-design", terminalID: "t1"))
    try await settle(screen, until: "the terminal's surface") { terminalSurface(screen) != nil }
    try await pause(screen, .milliseconds(200))
    let surface = frameInWindow(try #require(terminalSurface(screen)))
    #expect(abs(surface.maxY - bottom) < 0.5, "the surface's top \(surface.maxY), not \(bottom)")
    #expect(surface.height > 100)
  }
}
