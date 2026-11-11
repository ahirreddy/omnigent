import AppKit
import Foundation
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentUIComponents

#if DEBUG
  extension BudgetWindow {
    /// The replies laid out in the chats the window has built, shown or kept behind, sorted.
    func builtReplies() throws -> [String] {
      try screen.shownText().filter { $0.contains(" reply") }.sorted()
    }

    /// How many chats the window draws, by their composers: one kept behind draws none.
    var drawnChats: Int {
      screen.drawnViews.compactMap { $0 as? NSTextView }.filter(\.isEditable).count
    }

    /// Shows `sessionID` with a reply in its chat and comes back, so the chat stays built
    /// behind the shown one.
    func keepBuilt(_ sessionID: String, reply: String) async throws {
      selection.page = .session(sessionID)
      try await settleUntilQuiet()
      let text = try await text(afterReply: reply, in: sessionID)
      try #require(text.contains(reply), "the chat that is kept: \(text)")
      selection.page = .session(Self.shown)
      try await settleUntilQuiet()
    }

    /// Puts the side chat beside Alpha's chat, which keeps the focus, in a window wide enough
    /// for both.
    func splitWithSideChat() async throws {
      screen.window.setContentSize(CGSize(width: 1_300, height: 700))
      screen.settle(0.3)
      tabs.show(sideChatTabID, in: .trailing)
      tabs.focus(.leading)
      try await settleUntilQuiet()
      let replies = try builtReplies()
      try #require(replies.contains("Beta reply"), "the side chat's reply: \(replies)")
      try #require(drawnChats == 2, "a chat in each pane")
    }
  }

  nonisolated extension WindowInteraction {
    /// What nothing built behind the shown chat may take part in.
    private static let reachesOnlyTheShownTab = CountLimit.atMost([
      "shown tab measure": 1, "shown tab place": 1,
    ])

    /// A session kept open that shows again, as its chat was: nothing in it is built again.
    private static let keptSessionSwitch = [
      "composer": 2, "detail": 1, "rows": 1, "screen": 1, "session row": 4, "strip": 1,
      "tab": 1, "tab controls": 1, "transcript": 1,
    ]

    /// Chats kept built: in a split's panes, behind the shown tab and in other sessions.
    static let kept: [WindowInteraction] = split + hiddenChats

    private static let split: [WindowInteraction] = [
      WindowInteraction(
        name: "a session switch away from a split session, to one kept open",
        budget: keptSessionSwitch,
        prepare: { window in
          try await window.keepBuilt(BudgetWindow.other, reply: "Gamma reply")
          try await window.splitWithSideChat()
          window.noteScrollViews()
        },
        perform: { $0.selection.page = .session(BudgetWindow.other) },
        verify: { window in
          #expect(window.title == "Gamma")
          #expect(window.drawnChats == 1, "one chat, over both panes")
          let rebuilt = window.rebuiltScrollViews
          #expect(rebuilt.isEmpty, "the panes' chats stay built behind it: \(rebuilt)")
        }),
      WindowInteraction(
        name: "a session switch back to a split session",
        // Both panes' chats take the window's new values; neither builds a row again.
        budget: [
          "composer": 3, "detail": 1, "rows": 2, "screen": 2, "session row": 4, "strip": 1,
          "tab": 2, "tab controls": 1, "transcript": 2,
        ],
        prepare: { window in
          try await window.splitWithSideChat()
          window.selection.page = .session(BudgetWindow.other)
          try await window.settleUntilQuiet()
          window.noteScrollViews()
        },
        perform: { $0.selection.page = .session(BudgetWindow.shown) },
        verify: { window in
          #expect(window.title == "Alpha")
          #expect(window.tabs.split != nil, "the session is split as it was left")
          #expect(window.drawnChats == 2, "a chat in each pane")
          let rebuilt = window.rebuiltScrollViews
          #expect(rebuilt.isEmpty, "the panes' chats were kept: \(rebuilt)")
        }),
      WindowInteraction(
        name: "a composer keystroke in a split, with another session kept open",
        budget: ["composer": 1],
        layouts: reachesOnlyTheShownTab,
        prepare: { window in
          try await window.keepBuilt(BudgetWindow.other, reply: "Gamma reply")
          try await window.splitWithSideChat()
          try window.focusComposer()
          try await window.settleUntilQuiet()
          try window.screen.type("j")
        },
        perform: { try $0.screen.type("k") },
        verify: { window in
          #expect(window.editor?.string == "jk")
          for (sessionID, draft) in [
            BudgetWindow.shown: "jk", BudgetWindow.hidden: "", BudgetWindow.other: "",
          ] {
            let composer = try window.conversation(sessionID).composer
            #expect(composer.text == draft, "\(sessionID)'s draft")
          }
        }),
    ]

    private static let hiddenChats: [WindowInteraction] = [
      WindowInteraction(
        name: "a streamed delta into a hidden tab's chat",
        budget: [:],
        layouts: .atMost([:]),
        later: .atMost([:]),
        // A chat's first change after it was built renders its rows once more.
        prepare: { try $0.stream("Beta reply, first delta", in: BudgetWindow.hidden) },
        perform: { try $0.stream("Beta reply, second delta", in: BudgetWindow.hidden) },
        verify: { window in
          let hidden = try window.screen.shownText()
          #expect(!hidden.contains { $0.contains("second delta") }, "left as it hid: \(hidden)")
          window.tabs.select(window.sideChatTabID)
          try await window.settleUntilQuiet()
          let replies = try window.builtReplies()
          #expect(replies.contains("Beta reply, second delta"), "current once shown: \(replies)")
        }),
      WindowInteraction(
        name: "a streamed delta into the chat of a session kept open",
        budget: [:],
        layouts: .atMost([:]),
        later: .atMost([:]),
        prepare: { window in
          try await window.keepBuilt(BudgetWindow.other, reply: "Gamma reply")
          try window.stream("Gamma reply, first delta", in: BudgetWindow.other)
        },
        perform: { try $0.stream("Gamma reply, second delta", in: BudgetWindow.other) },
        verify: { window in
          let hidden = try window.screen.shownText()
          #expect(!hidden.contains { $0.contains("second delta") }, "left as it hid: \(hidden)")
          #expect(window.drawnChats == 1, "the shown chat alone draws")
        }),
      WindowInteraction(
        name: "back to a session kept open whose transcript changed behind the window",
        // The reply's row renders with its new text, in the pass that shows the chat.
        budget: keptSessionSwitch.merging(["markdown": 1, "row": 2, "rows": 2]) { $1 },
        prepare: { window in
          try await window.keepBuilt(BudgetWindow.other, reply: "Gamma reply")
          try window.stream("Gamma reply, changed", in: BudgetWindow.other, streaming: false)
        },
        perform: { window in
          window.selection.page = .session(BudgetWindow.other)
          // No task of the app runs inside a step, so no later update can bring the text.
          window.screen.settle(0.05)
          let replies = try window.builtReplies()
          #expect(replies.contains("Gamma reply, changed"), "current as it shows: \(replies)")
        },
        verify: { window in
          #expect(window.title == "Gamma")
          #expect(window.drawnChats == 1)
          let replies = try window.builtReplies()
          #expect(!replies.contains("Gamma reply"), "nothing of what it hid with: \(replies)")
        }),
    ]
  }
#endif
