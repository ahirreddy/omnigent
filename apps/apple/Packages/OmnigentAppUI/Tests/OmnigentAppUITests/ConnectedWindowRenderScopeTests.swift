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
  /// What a change to one session renders in the mounted window: the part that shows it, not the
  /// window. A window that follows the whole session list in its root rebuilds its toolbar and
  /// every open tab for each row the server sends. Each test also reads the new value where it is
  /// drawn, so a scope narrowed too far fails as stale.
  extension ConnectedWindowFlowTests {
    private struct TitledWindow {
      let screen: OffscreenWindow<AppWindowRoot>
      let session: ServerSession
      /// The side chat's tab, kept built behind the chat.
      let sideChatID: String
    }

    /// A titled window on `conv_a` with a side chat on `conv_b` kept built behind it.
    private func windowWithSideChat() async throws -> TitledWindow {
      let session = try await signedInSession(threeSessionServer())
      let screen = try await titledWindow(session, page: .session("conv_a"))
      let group = session.tabs.group("conv_a")
      let chat = try #require(group.tabs.first)
      group.open(.sideChatSession(parentID: "conv_a", childID: "conv_b"))
      try await settle(screen, until: "the side chat") {
        session.connection.conversations["conv_b"] != nil
      }
      let sideChat = try #require(group.selectedID)
      group.select(chat.id)
      try await pause(screen, .milliseconds(300))
      return TitledWindow(screen: screen, session: session, sideChatID: sideChat)
    }

    /// What renders when `sessionID`'s row arrives with a new title, preview and time.
    private func renders(
      _ window: TitledWindow, whenRowChanges sessionID: String
    ) throws -> [String: Int] {
      let list = window.session.connection.sessionList
      var row = try #require(list.session(sessionID))
      row.title = "Title of \(sessionID)"
      row.preview = "Changed"
      row.updatedAt += 100
      return RenderTally.recording {
        list.apply(.upsert(sessions: [row]))
        window.screen.settle(0.2)
      }
    }

    @Test("Another session's row renders the sidebar, not the window or the open chats")
    func anotherSessionsRowRendersTheSidebarOnly() async throws {
      let window = try await windowWithSideChat()
      defer { window.screen.close() }
      let renders = try renders(window, whenRowChanges: "conv_c")
      #expect(renders == ["sidebar": 1], "\(renders)")
      #expect(try window.screen.shows("Title of conv_c"))
    }

    @Test("A hidden tab's session renders that tab, which shows the new title once selected")
    func aKeptTabsRowRendersItsTab() async throws {
      let window = try await windowWithSideChat()
      defer { window.screen.close() }
      let renders = try renders(window, whenRowChanges: "conv_b")
      #expect(renders["shell"] == nil, "\(renders)")
      #expect(renders["strip"] == nil, "\(renders)")
      #expect(renders["tab"] == 1, "\(renders)")
      #expect(renders["screen"] == 1, "\(renders)")
      #expect(try window.screen.shows("Title of conv_b"), "the sidebar's row")
      #expect(window.screen.window.title == "Untitled session", "the shown chat keeps its title")
      window.session.tabs.group("conv_a").select(window.sideChatID)
      try await pause(window.screen, .milliseconds(300))
      #expect(window.screen.window.title == "Title of conv_b")
    }

    @Test("The shown session's row renders its chat, the strip and the sidebar, not the window")
    func theShownSessionsRowRendersItsChat() async throws {
      let window = try await windowWithSideChat()
      defer { window.screen.close() }
      let renders = try renders(window, whenRowChanges: "conv_a")
      #expect(renders["shell"] == nil, "\(renders)")
      #expect(renders["sidebar"] == 1, "\(renders)")
      #expect(renders["strip"] == 1, "\(renders)")
      #expect(try window.screen.shows("Title of conv_a"), "the sidebar's row")
      #expect(try window.screen.toolbarText().contains("Title of conv_a"), "the strip's tab")
      #expect(window.screen.window.title == "Title of conv_a", "the chat's own title")
    }
  }
#endif
