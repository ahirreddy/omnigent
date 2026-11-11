import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentUIComponents

#if DEBUG
  nonisolated extension WindowInteraction {
    /// Pages without a session (Usage here), shown over a session's kept chats, and the way back.
    static let pages: [WindowInteraction] = [
      WindowInteraction(
        name: "a page without a session",
        budget: toPage,
        perform: {
          $0.noteScrollViews()
          $0.selection.page = .usage
        },
        verify: { try pageIsShown(.usage, in: $0) }),
      WindowInteraction(
        name: "a page chosen in the sidebar",
        budget: toPage.merging(["inbox": 1]) { $1 },
        perform: {
          $0.noteScrollViews()
          try $0.chooseSidebarRow("Inbox")
        },
        verify: { window in
          try pageIsShown(.inbox, in: window)
          let text = try window.screen.shownText()
          #expect(text.contains("Nothing waiting on you"), "the page the row is for: \(text)")
        }),
      WindowInteraction(
        name: "a page the tab model shows by itself",
        budget: toPage,
        perform: {
          $0.noteScrollViews()
          $0.session.tabs.show(.usage)
        },
        verify: { try pageIsShown(.usage, in: $0) }),
      WindowInteraction(
        name: "back from a page without a session",
        budget: backFromPage,
        prepare: showPage,
        perform: { $0.selection.page = .session(BudgetWindow.shown) },
        verify: sessionIsBack),
      WindowInteraction(
        name: "a session chosen in the sidebar over a page",
        budget: backFromPage,
        prepare: showPage,
        perform: { try $0.choose(session: BudgetWindow.shown) },
        verify: sessionIsBack),
      WindowInteraction(
        name: "a session the tab model shows by itself over a page",
        budget: backFromPage,
        prepare: showPage,
        perform: { $0.session.tabs.show(.session(BudgetWindow.shown)) },
        verify: sessionIsBack),
    ]

    private typealias Check = @MainActor @Sendable (BudgetWindow) async throws -> Void

    /// Going to a page: the detail and the sidebar's rows, whose list reads the selection. The
    /// strip leaves without rendering, and the chats kept under the page are not rendered.
    private static let toPage = ["composer": 1, "detail": 1, "session row": 4, "tab": 1]

    /// Back to the session: the detail, the strip and the chat that was kept, once each, and
    /// never the leaving page's body or the chats kept behind the shown one.
    private static let backFromPage = [
      "composer": 1, "detail": 1, "rows": 1, "screen": 1, "session row": 4, "strip": 1,
      "tab": 1, "tab controls": 1, "transcript": 1,
    ]

    /// Shows the Usage page over the shown session, noting the chats' scroll views first.
    private static let showPage: Step = { window in
      window.noteScrollViews()
      window.selection.page = .usage
      window.screen.settle(0.3)
    }

    @MainActor
    private static func pageIsShown(_ page: SidebarDestination, in window: BudgetWindow) throws {
      #expect(window.selection.page == page, "the host's selection is the page")
      #expect(window.session.tabs.page == page, "and the tab model's")
      let toolbar = try window.screen.toolbarText()
      #expect(!toolbar.contains("Alpha"), "no strip over a page: \(toolbar)")
      #expect(!window.notes.scrollViews.isEmpty, "the chats had scroll views to keep")
      let rebuilt = window.rebuiltScrollViews
      #expect(rebuilt.isEmpty, "the chats stay built under the page, not \(rebuilt)")
    }

    private static let sessionIsBack: Check = { window in
      #expect(window.selection.page == .session(BudgetWindow.shown), "the host's selection")
      #expect(window.session.tabs.page == .session(BudgetWindow.shown), "and the tab model's")
      let toolbar = try window.screen.toolbarText()
      #expect(toolbar.contains("Alpha"), "the strip's tab is back: \(toolbar)")
      let text = try window.screen.shownText()
      #expect(text.contains("Alpha reply"), "the chat that was kept behind: \(text)")
      let rebuilt = window.rebuiltScrollViews
      #expect(rebuilt.isEmpty, "the same chat, not one built again: \(rebuilt)")
    }
  }
#endif
