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
  private func tabsBottom(_ screen: Screen) -> CGFloat {
    screen.window.contentLayoutRect.maxY
  }

  /// Whether `top` is where the tabs end: below them by the one pixel that keeps a page out of
  /// the title bar's safe area, and no more.
  private func startsAtTheTabs(_ top: CGFloat?, _ screen: Screen) -> Bool {
    guard let top else { return false }
    let bottom = tabsBottom(screen)
    return top < bottom && bottom - top <= 1
  }

  /// The top of what `view` draws, in window coordinates: its scroll view clips a row.
  private func drawnTop(_ view: NSView) -> CGFloat {
    view.convert(view.visibleRect, to: nil).maxY
  }

  /// The scroll views drawn in the detail, the transcript's among them.
  private func detailScrollViews(_ screen: Screen) -> [NSScrollView] {
    screen.drawnViews.compactMap { $0 as? NSScrollView }.filter {
      frameInWindow($0).minX >= sidebarEdge && $0.frame.height > 100 && !$0.visibleRect.isEmpty
    }
  }

  /// The chat's transcript: the tallest scroll view in the detail.
  private func transcript(_ screen: Screen) -> NSScrollView? {
    detailScrollViews(screen).max { $0.frame.height < $1.frame.height }
  }

  private func terminalSurface(_ screen: Screen) -> NSView? {
    screen.drawnViews.first { String(describing: type(of: $0)) == "TerminalSurfaceNSView" }
  }

  /// Waits for the chat's transcript to start where the tabs end, with no scroll view above.
  private func expectTranscriptAtTheTabs(_ screen: Screen) async throws {
    try await settle(screen, until: "the transcript where the tabs end") {
      startsAtTheTabs(transcript(screen).map { frameInWindow($0).maxY }, screen)
    }
    let tops = detailScrollViews(screen).map(drawnTop)
    let bottom = tabsBottom(screen)
    #expect(tops.allSatisfy { $0 < bottom }, "scroll views under the tabs (\(bottom)): \(tops)")
  }

  /// Waits for the terminal's surface to start where the tabs end, so its grid is what shows.
  private func expectSurfaceAtTheTabs(_ screen: Screen) async throws {
    try await settle(screen, until: "the terminal's surface where the tabs end") {
      startsAtTheTabs(terminalSurface(screen).map { frameInWindow($0).maxY }, screen)
    }
    let surface = frameInWindow(try #require(terminalSurface(screen)))
    #expect(surface.maxY < tabsBottom(screen), "its top \(surface.maxY), \(tabsBottom(screen))")
    #expect(surface.height > 100)
  }

  @Test("A chat's transcript and a terminal's surface start where the tabs end, split or not")
  func chatAndTerminal() async throws {
    let session = try await connectedDemo()
    let screen = try await titledWindow(
      session, selection: WindowSelection(.session("demo-design")))
    defer { screen.close() }
    try await settle(screen, until: "the tabs in the toolbar") {
      screen.window.toolbar?.items.isEmpty == false
    }
    let contentTop = frameInWindow(screen.host).maxY
    try #require(contentTop - tabsBottom(screen) > 40, "the toolbar floats over the content")
    try await expectTranscriptAtTheTabs(screen)

    let tabs = try #require(session.tabs.current)
    let terminal = tabs.open(.terminal(sessionID: "demo-design", terminalID: "t1"))
    try await expectSurfaceAtTheTabs(screen)

    // Side by side: the chat in one pane and the terminal in the other.
    tabs.show(terminal.id, in: .trailing)
    try await settle(screen, until: "the chat beside the terminal") {
      guard let chat = transcript(screen), let surface = terminalSurface(screen) else {
        return false
      }
      return frameInWindow(surface).minX >= frameInWindow(chat).maxX
    }
    try await expectTranscriptAtTheTabs(screen)
    try await expectSurfaceAtTheTabs(screen)
  }
}
