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
  /// The widths a resize changes: the sidebar, the chat's transcript and the titlebar's tabs.
  nonisolated struct ShownWidths: Equatable {
    var sidebar: CGFloat
    var transcript: CGFloat
    var strip: CGFloat

    /// These widths with `points` moved from the chat to the sidebar.
    func sidebarWider(by points: CGFloat) -> Self {
      Self(sidebar: sidebar + points, transcript: transcript - points, strip: strip - points)
    }
  }

  /// What a step noted for its check afterwards.
  @MainActor
  final class BudgetNotes {
    var widths: ShownWidths?
    /// What the window drew before the step put a preference back.
    var text: [String] = []
    /// A stored preference as it was before the step wrote it.
    var stored: Any?
    /// The chats' scroll views as they were built before the step.
    var scrollViews: [NSScrollView] = []
  }

  extension BudgetWindow {
    /// The split between the sidebar and the chat.
    var split: NSSplitView {
      get throws {
        let splits = screen.allViews.compactMap { $0 as? NSSplitView }
        return try #require(splits.first { $0.isVertical && $0.arrangedSubviews.count >= 2 })
      }
    }

    /// The sidebar's search field.
    func searchField() throws -> NSSearchField {
      try #require(screen.allViews.compactMap { $0 as? NSSearchField }.first)
    }

    /// The widths the window draws at now.
    var widths: ShownWidths {
      get throws {
        let scrolls = screen.allViews.compactMap { $0 as? NSScrollView }
        let items = screen.window.toolbar?.items.compactMap(\.view) ?? []
        return ShownWidths(
          sidebar: try split.arrangedSubviews[0].frame.width,
          transcript: try #require(scrolls.map(\.frame.width).max()),
          strip: try #require(items.map(\.frame.width).max()))
      }
    }

    /// Notes the scroll views the window has built, before a step that must keep them.
    func noteScrollViews() {
      notes.scrollViews = screen.allViews.compactMap { $0 as? NSScrollView }
    }

    /// How many of the noted scroll views the window no longer holds: it built them again.
    var rebuiltScrollViews: Int {
      let held = Set(screen.allViews.map(ObjectIdentifier.init))
      return notes.scrollViews.count { !held.contains(ObjectIdentifier($0)) }
    }

    /// Notes the widths before a step that changes them.
    func noteWidths() throws {
      notes.widths = try widths
    }

    /// How many chats, shown or kept behind, have their right panel open as a column.
    var openPanels: Int {
      get throws {
        let outer = try split
        let splits = screen.allViews.compactMap { $0 as? NSSplitView }
        return splits.count { panel in
          panel !== outer && panel.arrangedSubviews.count == 2
            && !panel.isSubviewCollapsed(panel.arrangedSubviews[1])
        }
      }
    }

    /// Writes a preference the way Settings does, noting what it replaces.
    func store(_ value: Any, forKey key: String) {
      notes.stored = preferences.object(forKey: key)
      preferences.set(value, forKey: key)
    }

    /// Notes what the window draws, then puts the noted preference back: a step's `afterwards`
    /// does this, and its check reads both.
    func putBack(_ key: String) throws {
      notes.text = try screen.shownText()
      preferences.set(notes.stored, forKey: key)
    }
  }

  nonisolated extension WindowInteraction {
    /// The window's own size and panels.
    static let layout: [WindowInteraction] = [
      WindowInteraction(
        name: "a window resize step",
        budget: ["strip": 1],
        prepare: { try $0.noteWidths() },
        perform: { $0.screen.window.setContentSize(CGSize(width: 860, height: 600)) },
        verify: { window in
          let before = try #require(window.notes.widths)
          var narrower = before
          narrower.transcript -= 40
          narrower.strip -= 40
          #expect(try window.widths == narrower, "from \(before)")
        }),
      WindowInteraction(
        name: "a sidebar divider step",
        budget: ["strip": 1],
        prepare: { try $0.noteWidths() },
        perform: { window in
          let split = try window.split
          split.setPosition(split.arrangedSubviews[0].frame.width + 20, ofDividerAt: 0)
          // The window lays itself out before it draws; without it the next settle lays the
          // split out by itself, at a width the window then takes back.
          window.screen.window.layoutIfNeeded()
        },
        verify: { window in
          let before = try #require(window.notes.widths)
          #expect(try window.widths == before.sidebarWider(by: 20), "from \(before)")
        }),
      WindowInteraction(
        name: "the right panel shown",
        budget: ["composer": 1, "rows": 1, "screen": 1, "transcript": 1],
        prepare: { window in
          let open = try window.openPanels
          try #require(open == 0, "a panel is open before its shortcut")
        },
        perform: { window in
          let handled = try pressShortcut(
            window.screen, keyCode: 30, characters: "]", modifiers: [.command, .option])
          try #require(handled, "nothing answered the right panel's shortcut")
        },
        verify: { window in
          let open = try window.openPanels
          #expect(open == 1, "the shown chat's panel, and not the hidden one's")
          // Showing it becomes the default for the next chat, in the window's own preferences.
          let stored = window.preferences.string(forKey: panelKey)
          #expect(stored == WorkspacePanelDefault.open.rawValue)
        }),
    ]

    private static let panelKey = InterfacePreferences.workspacePanelKey

    /// A key no view reads. It has a dot in it, as the keys `@AppStorage` cannot watch singly do.
    private static let unreadKey = "omnigent.tests.unread-preference"

    /// What the composer's hint calls the key that sends once Command-Return does.
    private static let commandReturnHint = "\u{2318}\u{21B5} to "

    /// The stored preferences: one a chat reads, and one nothing in the window does.
    static let preferences: [WindowInteraction] = [
      WindowInteraction(
        name: "a preference no view reads",
        budget: [:],
        perform: { $0.store(true, forKey: unreadKey) },
        afterwards: { try $0.putBack(unreadKey) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("Alpha reply"), "the chat still draws: \(text)")
        }),
      WindowInteraction(
        name: "a preference no view reads, over the new session page",
        budget: [:],
        prepare: { window in
          window.choose(.newSession)
          window.screen.settle(0.3)
        },
        perform: { $0.store(true, forKey: unreadKey) },
        afterwards: { try $0.putBack(unreadKey) },
        verify: { window in
          let text = try window.screen.shownText()
          #expect(text.contains("What should we build?"), "the page still draws: \(text)")
        }),
      WindowInteraction(
        name: "the Command-Return setting",
        budget: ["composer": 2, "rows": 2, "screen": 2, "transcript": 2],
        prepare: { window in
          let text = try window.screen.shownText()
          try #require(!text.contains { $0.contains(commandReturnHint) }, "\(text)")
        },
        perform: { $0.store(true, forKey: ComposerPreferences.submitWithCommandReturnKey) },
        afterwards: { try $0.putBack(ComposerPreferences.submitWithCommandReturnKey) },
        verify: { window in
          let changed = window.notes.text
          #expect(changed.contains { $0.contains(commandReturnHint) }, "the hint: \(changed)")
          let text = try window.screen.shownText()
          #expect(!text.contains { $0.contains(commandReturnHint) }, "and back again: \(text)")
        }),
    ]
  }
#endif
