import AppKit
import Foundation
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentUIComponents

/// The titlebar's tab strip takes the width the window's trailing toolbar items leave. A page
/// focused beside a chat shows none and the chat stops showing its own, so the page's tabs
/// reach New Tab instead of stopping at room kept for buttons that are not there.
@MainActor
@Suite("The tab strip's room beside a chat", .serialized, .timeLimit(.minutes(1)))
struct TitlebarStripRoomTests {
  private typealias Screen = OffscreenWindow<AppWindowRoot>

  private static let sessionID = "demo-design"

  /// The strip's toolbar item, the widest in the toolbar.
  private func stripWidth(_ screen: Screen) -> CGFloat {
    screen.window.toolbar?.items.compactMap(\.view).map(\.frame.width).max() ?? 0
  }

  /// The detail column, right of the sidebar.
  private func detailWidth(_ screen: Screen) throws -> CGFloat {
    let splits = screen.allViews.compactMap { $0 as? NSSplitView }
    let columns = try #require(splits.first { $0.isVertical && $0.arrangedSubviews.count >= 2 })
    return columns.arrangedSubviews[1].frame.width
  }

  /// The strip's width in `screen` beside `items` trailing button widths.
  private func strip(beside items: Int, in screen: Screen) throws -> CGFloat {
    TitlebarMetrics.stripWidth(
      detailWidth: try detailWidth(screen), isSidebarHidden: false, trailingItems: items)
  }

  @Test("Links opened beside a chat get the room of the toolbar items the chat stops showing")
  func pagesBesideAChat() async throws {
    let session = try await connectedDemo()
    let context = TabWindowContext(browser: FakeBrowserHost())
    let screen = try await titledWindow(
      session, selection: WindowSelection(.session(Self.sessionID)), tabContext: context)
    defer { screen.close() }
    screen.window.setContentSize(CGSize(width: 1_500, height: 700))
    try await settle(screen, until: "the tabs in the toolbar") { stripWidth(screen) > 0 }
    try await pause(screen, .milliseconds(400))
    let besideTheChatsItems = stripWidth(screen)
    try #require(besideTheChatsItems < (try strip(beside: 0, in: screen)), "the chat has items")

    let tabs = WindowTabs(session: session, context: context, showAll: {}, fail: { _ in })
    for page in ["a", "b", "c"] {
      let link = try #require(URL(string: "https://example.com/\(page)"))
      tabs.openLinkBeside(link, in: Self.sessionID)
    }
    let group = try #require(session.tabs.current)
    #expect(group.split?.trailing.count == 3, "each link is a tab of the pane beside the chat")
    #expect(group.split?.focused == .trailing)

    let reachingNewTab = try strip(beside: 0, in: screen)
    try await settle(screen, until: "the strip to reach New Tab") {
      stripWidth(screen) == reachingNewTab
    }
    #expect(stripWidth(screen) == reachingNewTab, "kept for the chat: \(besideTheChatsItems)")
    let folded = screen.window.toolbar?.items.filter { !$0.isVisible } ?? []
    #expect(folded.isEmpty, "the wider strip folds no toolbar item")

    // The chat's pane takes the focus back, and its toolbar items their room.
    group.focus(.leading)
    try await settle(screen, until: "the strip beside the chat's items again") {
      stripWidth(screen) == besideTheChatsItems
    }
    #expect(stripWidth(screen) == besideTheChatsItems)
  }
}
