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
    /// The budget table: every interaction the window is held to.
    static let all: [WindowInteraction] = sessionRows + chat + navigation + sidebar

    /// The server's news about one session.
    private static let sessionRows: [WindowInteraction] = [
      WindowInteraction(
        name: "another session's row",
        budget: ["session row": 5, "sidebar": 1],
        perform: { window in
          try window.change(BudgetWindow.other) { $0.title = "Gamma renamed" }
          try window.activity(in: BudgetWindow.other, minutesAgo: 7)
        },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Gamma renamed") && text.contains("7m"), "\(text)")
        }),
      WindowInteraction(
        name: "the shown session's preview and time",
        budget: ["session row": 4, "sidebar": 1],
        perform: { try $0.activity(in: BudgetWindow.shown, minutesAgo: 5) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("5m") && !text.contains("3m"), "the sidebar's row: \(text)")
        }),
      WindowInteraction(
        name: "a hidden tab's session's preview and time",
        budget: ["session row": 4, "sidebar": 1],
        perform: { try $0.activity(in: BudgetWindow.hidden, minutesAgo: 9) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("9m") && !text.contains("4m"), "the sidebar's row: \(text)")
        }),
      WindowInteraction(
        name: "the shown session's title",
        budget: [
          "composer": 2, "rows": 2, "screen": 2, "session row": 5, "sidebar": 1, "strip": 1,
          "tab": 2, "tab controls": 1, "transcript": 2,
        ],
        perform: { try $0.change(BudgetWindow.shown) { $0.title = "Alpha renamed" } },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Alpha renamed"), "the sidebar's row: \(text)")
          let toolbar = try window.screen.toolbarText()
          #expect(toolbar.contains("Alpha renamed"), "the strip's tab: \(toolbar)")
          #expect(window.title == "Alpha renamed", "the chat's own title")
        }),
      WindowInteraction(
        name: "a hidden tab's session's title",
        budget: [
          "composer": 1, "rows": 1, "screen": 1, "session row": 5, "sidebar": 1, "tab": 1,
          "transcript": 1,
        ],
        perform: { try $0.change(BudgetWindow.hidden) { $0.title = "Beta renamed" } },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Beta renamed"), "the sidebar's row: \(text)")
          #expect(window.title == "Alpha", "the shown chat keeps its title")
          window.tabs.select(window.sideChatTabID)
          window.screen.settle(0.3)
          #expect(window.title == "Beta renamed", "the tab's title once it shows")
        }),
      WindowInteraction(
        name: "a session that needs the user",
        budget: ["session row": 5, "sidebar": 1],
        perform: { try $0.change(BudgetWindow.other) { $0.pendingRequests = 7 } },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(
            text.contains("7") && !text.contains("6m"), "its row counts the requests: \(text)")
        }),
      WindowInteraction(
        name: "a session marked unread",
        budget: ["session row": 4, "sidebar": 1],
        perform: { $0.list.unreadIDs.insert(BudgetWindow.other) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Gamma") && !text.contains("6m"), "a dot for its time: \(text)")
        }),
    ]

    /// The shown chat's own work.
    private static let chat: [WindowInteraction] = [
      WindowInteraction(
        name: "a streamed delta",
        budget: [:],
        perform: { try $0.stream("Alpha reply and one more delta", in: BudgetWindow.shown) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains { $0.contains("one more delta") }, "\(text)")
        }),
      WindowInteraction(
        name: "a draft's first keystroke",
        budget: [
          "composer": 1, "rows": 1, "screen": 1, "session row": 4, "sidebar": 1, "transcript": 1,
        ],
        perform: { try $0.screen.type("k") },
        verify: { window in
          #expect(window.editor?.string == "k")
          window.selection.page = .session(BudgetWindow.other)
          window.screen.settle(0.3)
          let text = try window.screen.shownText()
          #expect(!text.contains("3m"), "a pencil for the row's time once it is left: \(text)")
        }),
      WindowInteraction(
        name: "a composer keystroke",
        budget: ["composer": 1],
        prepare: { try $0.screen.type("j") },
        perform: { try $0.screen.type("k") },
        verify: { window in
          #expect(window.editor?.string == "jk")
          let composer = try window.conversation(BudgetWindow.shown).composer
          #expect(composer.text == "jk")
        }),
    ]

    /// Moving between tabs and sessions.
    private static let navigation: [WindowInteraction] = [
      WindowInteraction(
        name: "a tab switch",
        budget: [
          "composer": 2, "detail": 1, "rows": 1, "screen": 1, "strip": 1, "tab": 1,
          "tab controls": 1, "transcript": 1,
        ],
        perform: { $0.tabs.select($0.sideChatTabID) },
        verify: { window in
          #expect(window.title == "Beta")
          let text = try window.screen.shownText()
          #expect(text.contains("Beta reply"), "the tab that was kept behind: \(text)")
        }),
      WindowInteraction(
        name: "a session switch",
        budget: [
          "composer": 4, "detail": 2, "rows": 3, "screen": 3, "session row": 4, "shell": 1,
          "sidebar": 1, "strip": 2, "tab": 2, "tab controls": 2, "transcript": 3, "window": 1,
        ],
        perform: { $0.selection.page = .session(BudgetWindow.other) },
        verify: { window in
          #expect(window.title == "Gamma")
          let toolbar = try window.screen.toolbarText()
          #expect(toolbar.contains("Gamma"), "the strip's tab: \(toolbar)")
          let text = try await window.text(afterReply: "Gamma reply", in: BudgetWindow.other)
          #expect(text.contains("Gamma reply"), "the chat that opened after its tab: \(text)")
        }),
      WindowInteraction(
        name: "a session chosen in the sidebar",
        budget: [
          "composer": 3, "detail": 2, "rows": 2, "screen": 2, "session row": 4, "shell": 1,
          "sidebar": 1, "strip": 3, "tab": 2, "tab controls": 2, "transcript": 2, "window": 1,
        ],
        perform: { $0.choose(.session(BudgetWindow.other)) },
        verify: { window in
          #expect(window.title == "Gamma")
          let text = try await window.text(afterReply: "Gamma reply", in: BudgetWindow.other)
          #expect(text.contains("Gamma reply"), "the chat that opened after its tab: \(text)")
        }),
      WindowInteraction(
        name: "a session the window shows by itself",
        budget: [
          "composer": 3, "detail": 2, "rows": 2, "screen": 2, "session row": 4, "shell": 1,
          "sidebar": 1, "strip": 2, "tab": 2, "tab controls": 2, "transcript": 2, "window": 1,
        ],
        perform: { $0.session.tabs.show(.session(BudgetWindow.other)) },
        verify: { window in
          #expect(window.selection.page == .session(BudgetWindow.other), "the host follows")
          #expect(window.title == "Gamma")
          let text = try await window.text(afterReply: "Gamma reply", in: BudgetWindow.other)
          #expect(text.contains("Gamma reply"), "the chat that opened after its tab: \(text)")
        }),
      WindowInteraction(
        name: "back to a session kept open",
        budget: [
          "composer": 3, "detail": 2, "rows": 2, "screen": 2, "session row": 4, "shell": 1,
          "sidebar": 1, "strip": 2, "tab": 2, "tab controls": 2, "transcript": 2, "window": 1,
        ],
        prepare: { window in
          window.selection.page = .session(BudgetWindow.other)
          window.screen.settle(0.3)
        },
        perform: { $0.selection.page = .session(BudgetWindow.shown) },
        verify: { window in
          #expect(window.title == "Alpha")
          let text = try window.screen.shownText()
          #expect(text.contains("Alpha reply"), "the chat that was kept behind: \(text)")
        }),
      WindowInteraction(
        name: "back to a session that closed",
        budget: [
          "composer": 4, "detail": 2, "rows": 3, "screen": 3, "session row": 4, "shell": 1,
          "sidebar": 1, "strip": 2, "tab": 3, "tab controls": 2, "transcript": 3, "window": 1,
        ],
        prepare: { try $0.leaveUntilClosed() },
        perform: { $0.selection.page = .session(BudgetWindow.shown) },
        verify: { window in
          #expect(window.title == "Alpha")
          let text = try await window.text(afterReply: "Alpha again", in: BudgetWindow.shown)
          #expect(text.contains("Alpha again"), "the chat that opened again: \(text)")
        }),
      WindowInteraction(
        name: "another session opening behind the window",
        budget: [:],
        perform: { $0.session.open(BudgetWindow.another) },
        verify: { window in
          #expect(window.session.terminals(of: BudgetWindow.another) != nil)
          let text = try await window.text(afterReply: "Alpha goes on", in: BudgetWindow.shown)
          #expect(text.contains("Alpha goes on"), "the shown chat still draws: \(text)")
        }),
      WindowInteraction(
        name: "another session closing behind the window",
        budget: [:],
        prepare: { $0.session.open(BudgetWindow.another) },
        perform: { $0.session.close(BudgetWindow.another) },
        verify: { window in
          #expect(window.session.terminals(of: BudgetWindow.another) == nil)
          let text = try await window.text(afterReply: "Alpha goes on", in: BudgetWindow.shown)
          #expect(text.contains("Alpha goes on"), "the shown chat still draws: \(text)")
        }),
      WindowInteraction(
        name: "a page without a session",
        budget: [
          "composer": 5, "detail": 4, "markdown": 6, "row": 6, "rows": 7, "screen": 7,
          "session row": 8, "shell": 2, "sidebar": 2, "strip": 1, "tab": 6, "tab controls": 1,
          "transcript": 7, "window": 2,
        ],
        perform: { $0.selection.page = .usage },
        verify: { window in
          let toolbar = try window.screen.toolbarText()
          #expect(!toolbar.contains("Alpha"), "no strip over a page: \(toolbar)")
        }),
      WindowInteraction(
        name: "back from a page without a session",
        budget: [
          "composer": 5, "detail": 4, "markdown": 6, "row": 6, "rows": 6, "screen": 7,
          "session row": 8, "shell": 2, "sidebar": 2, "strip": 1, "tab": 5, "tab controls": 1,
          "transcript": 6, "window": 2,
        ],
        prepare: { window in
          window.selection.page = .usage
          window.screen.settle(0.3)
        },
        perform: { $0.selection.page = .session(BudgetWindow.shown) },
        verify: { window in
          let toolbar = try window.screen.toolbarText()
          #expect(toolbar.contains("Alpha"), "the strip's tab is back: \(toolbar)")
          let text = try window.screen.shownText()
          #expect(text.contains("Alpha reply"), "the chat that was kept behind: \(text)")
        }),
    ]

    /// The sidebar's own controls.
    private static let sidebar: [WindowInteraction] = [
      WindowInteraction(
        name: "sidebar search text",
        budget: ["session row": 2, "sidebar": 1],
        perform: { $0.list.searchText = "ta" },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Beta") && text.contains("Delta"), "the matches: \(text)")
          #expect(!text.contains("Gamma"), "only the matches: \(text)")
        }),
      WindowInteraction(
        name: "a sidebar filter",
        budget: ["session row": 2, "sidebar": 1],
        prepare: { window in
          for sessionID in [BudgetWindow.other, BudgetWindow.another] {
            try window.change(sessionID) { $0.status = .running }
          }
        },
        perform: { $0.list.filter = .running },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Gamma") && text.contains("Delta"), "the running: \(text)")
          #expect(!text.contains("Beta"), "only the running: \(text)")
        }),
      WindowInteraction(
        name: "a page of sessions that finished loading",
        budget: ["session row": 4, "sidebar": 1],
        prepare: { try $0.showLoadingMore() },
        perform: { $0.list.paging.pagingChanged(hasMore: true, isLoading: false) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Load more") && !text.contains("Loading\u{2026}"), "\(text)")
        }),
      WindowInteraction(
        name: "the last page of sessions, with none in it",
        budget: ["session row": 4, "sidebar": 1],
        prepare: { try $0.showLoadingMore() },
        perform: { $0.list.paging.pagingChanged(hasMore: false, isLoading: false) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(!text.contains("Load more") && !text.contains("Loading\u{2026}"), "\(text)")
        }),
    ]
  }
#endif
