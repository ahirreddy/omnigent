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
    /// The session's toolbar controls, by the labels the toolbar gives them.
    static let sessionControls = ["Session", "Right panel"]

    /// The toolbar's item objects: an update in place keeps every one.
    var toolbarItems: [ObjectIdentifier] {
      (screen.window.toolbar?.items ?? []).map(ObjectIdentifier.init)
    }

    /// The session's controls the toolbar shows now.
    var shownSessionControls: [String] {
      (screen.window.toolbar?.visibleItems ?? []).map(\.label)
        .filter(Self.sessionControls.contains)
    }

    /// The frames of the transcripts of the chats kept behind the shown tab. Not their
    /// composers' text fields: the window's panel insets the trailing safe area, which a kept
    /// chat's composer bar follows.
    var keptChatFrames: [CGRect] {
      let drawn = Set(screen.drawnViews.map(ObjectIdentifier.init))
      let scrolls = screen.allViews.compactMap { $0 as? NSScrollView }
      return scrolls.filter { !drawn.contains(ObjectIdentifier($0)) }
        .filter { !($0.documentView is NSTextView) }.map(\.frame)
    }

    /// Opens a New Tab page beside the chat and notes its tab, the toolbar's items and the
    /// chats' sizes.
    /// - Parameter backOnChat: Leaves the chat on screen, the page's tab behind it.
    /// - Throws: When the window does not go quiet.
    func openPage(backOnChat: Bool) async throws {
      let page = tabs.open(.newTab)
      notes.pageTabID = page.id
      if backOnChat { tabs.select(chatTabID) }
      try await settleUntilQuiet()
      notes.toolbarItems = toolbarItems
      noteScrollViews()
      notes.keptChatFrames = keptChatFrames
    }
  }

  nonisolated extension WindowInteraction {
    /// The session's toolbar controls and right panel, which the window shows around its tabs.
    static let chrome: [WindowInteraction] = [
      WindowInteraction(
        name: "a tab switch from a chat to a tab of another kind",
        // The toolbar's session controls and the panel belong to the session, not to the tab:
        // nothing of them renders, and no toolbar item is added or removed. The chat's
        // composer gives up the keyboard.
        budget: ["composer": 1, "detail": 1, "strip": 1, "tab": 1, "tab controls": 1],
        prepare: { try await $0.openPage(backOnChat: true) },
        perform: { $0.tabs.select($0.notes.pageTabID) },
        verify: { window in
          #expect(window.tabs.selected?.content == .newTab)
          #expect(window.shownSessionControls == BudgetWindow.sessionControls)
          #expect(window.toolbarItems == window.notes.toolbarItems, "the same toolbar items")
          #expect(window.drawnChats == 0, "the chat is kept behind the page")
        }),
      WindowInteraction(
        name: "the right panel shown over a tab of another kind, two chats kept behind it",
        // The session chrome, which holds the panel; no chat behind the page renders or
        // changes size.
        budget: ["chrome": 1],
        prepare: { try await $0.openPage(backOnChat: false) },
        perform: { window in
          let handled = try pressShortcut(
            window.screen, keyCode: 30, characters: "]", modifiers: [.command, .option])
          try #require(handled, "nothing answered the right panel's shortcut")
        },
        verify: { window in
          let open = try window.openPanels
          #expect(open == 1, "the window's panel")
          #expect(window.rebuiltScrollViews.isEmpty, "the chats stay built")
          let frames = window.keptChatFrames
          #expect(!frames.isEmpty, "chats are kept behind the page")
          #expect(frames == window.notes.keptChatFrames, "as wide as they were on screen")
          #expect(window.toolbarItems == window.notes.toolbarItems, "the same toolbar items")
        }),
    ]
  }
#endif
