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
    static let all: [WindowInteraction] =
      sessionRows + chat + navigation + kept + pages + sidebar + layout + preferences

    /// The server's news about one session.
    private static let sessionRows: [WindowInteraction] = [
      WindowInteraction(
        name: "another session's row",
        budget: ["session row": 1],
        perform: { window in
          try window.change(BudgetWindow.other) { $0.title = "Gamma renamed" }
          try window.activity(in: BudgetWindow.other, minutesAgo: 7)
        },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Gamma renamed") && text.contains("7m"), "\(text)")
        }),
      WindowInteraction(
        name: "another session's files change",
        budget: [:],
        prepare: { $0.notes.requests = $0.server.http.requests.count },
        perform: { window in
          window.session.connection.apply(
            .changedFiles(
              sessionId: BudgetWindow.other, environmentId: "default", update: .loaded(files: [])))
        },
        verify: { window in
          // Each session works in a directory of its own, so no kept chat asks for its changes.
          let asked = window.changesAsked()
          #expect(asked.isEmpty, "\(asked)")
          let text = try window.screen.shownText()
          #expect(text.contains("Alpha reply"), "the chat still draws: \(text)")
        }),
      WindowInteraction(
        name: "a file changes in a session that shares the shown chat's workspace",
        budget: [:],
        prepare: { window in
          try window.change(BudgetWindow.other) { $0.workspace = "/work/\(BudgetWindow.shown)" }
          window.screen.settle(0.3)
          window.notes.requests = window.server.http.requests.count
        },
        perform: { window in
          window.session.connection.apply(
            .changedFiles(
              sessionId: BudgetWindow.other, environmentId: "default", update: .loaded(files: [])))
        },
        verify: { window in
          let asked = window.changesAsked()
          #expect(asked == [BudgetWindow.shown], "the chat in that directory, and no other")
          let text = try window.screen.shownText()
          #expect(text.contains("Alpha reply"), "the chat still draws: \(text)")
        }),
      WindowInteraction(
        name: "the shown session's preview and time",
        budget: ["session row": 1],
        perform: { try $0.activity(in: BudgetWindow.shown, minutesAgo: 2) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("2m") && !text.contains("3m"), "the sidebar's row: \(text)")
        }),
      WindowInteraction(
        name: "a hidden tab's session's preview and time",
        budget: ["session row": 1],
        perform: { try $0.activity(in: BudgetWindow.hidden, minutesAgo: 5) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("5m") && !text.contains("4m"), "the sidebar's row: \(text)")
        }),
      WindowInteraction(
        name: "activity that moves a session's row",
        // The row renders for what it says and again where the list puts it.
        budget: ["session row": 5, "sidebar": 1],
        perform: { try $0.activity(in: BudgetWindow.shown, minutesAgo: 5) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("5m") && !text.contains("3m"), "the sidebar's row: \(text)")
          let rows = try ["Beta", "Alpha", "Gamma"].map(window.sidebarRow)
          #expect(rows == rows.sorted(), "Alpha under Beta, which was active since: \(rows)")
        }),
      WindowInteraction(
        name: "the shown session's title",
        budget: [
          "composer": 2, "rows": 2, "screen": 2, "session row": 1, "strip": 1, "tab": 2,
          "tab controls": 1, "transcript": 2,
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
          "composer": 1, "rows": 1, "screen": 1, "session row": 1, "tab": 1, "transcript": 1,
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
        budget: ["session row": 1],
        perform: { try $0.change(BudgetWindow.other) { $0.pendingRequests = 7 } },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(
            text.contains("7") && !text.contains("6m"), "its row counts the requests: \(text)")
        }),
      WindowInteraction(
        name: "a session marked unread",
        budget: ["session row": 1],
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
        budget: ["composer": 1],
        perform: { try $0.screen.type("k") },
        verify: { window in
          #expect(window.editor?.string == "k")
          window.selection.page = .session(BudgetWindow.other)
          window.screen.settle(0.3)
          let text = try window.screen.shownText()
          #expect(!text.contains("3m"), "a pencil for the row's time once it is left: \(text)")
        }),
      WindowInteraction(
        name: "a draft's last character deleted",
        budget: ["composer": 1],
        prepare: { try $0.screen.type("j") },
        perform: { try $0.screen.press(keyCode: 51, characters: "\u{7F}") },
        verify: { window in
          #expect(window.editor?.string.isEmpty == true)
          window.selection.page = .session(BudgetWindow.other)
          window.screen.settle(0.3)
          let text = try window.screen.shownText()
          #expect(text.contains("3m"), "the row's time again, with no draft left: \(text)")
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

    /// A session that opens in the detail: its chat, the strip and the sidebar's rows, whose
    /// list reads the selection. The window, the shell and the sidebar's scope stay as they are.
    private static let sessionSwitch = [
      "composer": 3, "detail": 1, "rows": 2, "screen": 2, "session row": 4, "strip": 1,
      "tab": 1, "tab controls": 1, "transcript": 2,
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
        name: "back to a chat from a tab of another kind, three chats kept",
        // The strip renders again once the chat's toolbar items take their room beside it.
        budget: [
          "composer": 1, "detail": 1, "rows": 1, "screen": 1, "strip": 2, "tab": 1,
          "tab controls": 1, "transcript": 1,
        ],
        prepare: { window in
          window.tabs.open(
            .sideChatSession(parentID: BudgetWindow.shown, childID: BudgetWindow.other))
          window.screen.settle(0.5)
          _ = try window.conversation(BudgetWindow.other)
          window.tabs.select(window.chatTabID)
          window.screen.settle(0.3)
          window.noteScrollViews()
          window.tabs.open(.newTab)
          window.screen.settle(0.3)
        },
        perform: { $0.tabs.select($0.chatTabID) },
        verify: { window in
          #expect(window.title == "Alpha")
          let text = try window.screen.shownText()
          #expect(text.contains("Alpha reply"), "the chat that was kept behind: \(text)")
          #expect(window.notes.scrollViews.count >= 3, "three chats had scroll views to keep")
          let rebuilt = window.rebuiltScrollViews
          #expect(rebuilt.isEmpty, "the new tab took no chat's place: \(rebuilt)")
        }),
      WindowInteraction(
        name: "a session switch",
        budget: sessionSwitch,
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
        budget: sessionSwitch,
        perform: { try $0.choose(session: BudgetWindow.other) },
        verify: { window in
          #expect(window.selection.page == .session(BudgetWindow.other), "the host's selection")
          #expect(window.session.tabs.page == .session(BudgetWindow.other), "the tab model's")
          #expect(window.title == "Gamma")
          let toolbar = try window.screen.toolbarText()
          #expect(toolbar.contains("Gamma"), "the strip's tab: \(toolbar)")
          let text = try await window.text(afterReply: "Gamma reply", in: BudgetWindow.other)
          #expect(text.contains("Gamma reply"), "the chat that opened after its tab: \(text)")
        }),
      WindowInteraction(
        name: "a session the window shows by itself",
        budget: sessionSwitch,
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
          "composer": 2, "detail": 1, "rows": 1, "screen": 1, "session row": 4, "strip": 1,
          "tab": 1, "tab controls": 1, "transcript": 1,
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
        budget: sessionSwitch.merging(["tab": 2]) { $1 },
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
    ]

    /// The sidebar's own controls.
    private static let sidebar: [WindowInteraction] = [
      WindowInteraction(
        name: "sidebar search text",
        budget: ["search field": 1, "session row": 2, "sidebar": 1],
        perform: { $0.list.searchText = "ta" },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Beta") && text.contains("Delta"), "the matches: \(text)")
          #expect(!text.contains("Gamma"), "only the matches: \(text)")
          #expect(try window.searchField().stringValue == "ta", "the field shows it")
        }),
      WindowInteraction(
        name: "search text typed into the sidebar's field",
        budget: ["search field": 2, "session row": 6, "sidebar": 2],
        prepare: { window in
          let hasKeyboard = window.screen.window.makeFirstResponder(try window.searchField())
          try #require(hasKeyboard, "the search field takes the keyboard")
        },
        perform: { try $0.screen.type("ta") },
        verify: { window in
          #expect(window.list.searchText == "ta", "the field writes the session list's search")
          let text = try window.screen.shownText()
          #expect(text.contains("Beta") && !text.contains("Gamma"), "the matches: \(text)")
        }),
      WindowInteraction(
        name: "sidebar search text cleared",
        budget: ["search field": 1, "session row": 4, "sidebar": 1],
        prepare: { $0.list.searchText = "ta" },
        perform: { $0.list.searchText = "" },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Gamma") && text.contains("Beta"), "every session: \(text)")
          #expect(try window.searchField().stringValue.isEmpty, "the field is empty again")
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
