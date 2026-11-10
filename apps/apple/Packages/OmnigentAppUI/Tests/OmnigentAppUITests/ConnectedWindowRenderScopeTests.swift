import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentUIComponents

#if DEBUG
  /// What a change to one session renders in the mounted window: the part that shows it, not the
  /// window. A window that follows the whole session list in its root rebuilds its toolbar and
  /// every open tab for each row the server sends.
  extension ConnectedWindowFlowTests {
    /// The window on `conv_a` with a side chat on `conv_b` kept built behind it.
    private func mountedWithSideChat() async throws -> Mounted {
      let mounted = try await mounted()
      let group = mounted.session.tabs.group("conv_a")
      let chat = try #require(group.tabs.first)
      group.open(.sideChatSession(parentID: "conv_a", childID: "conv_b"))
      try await settle(mounted.screen, until: "the side chat") {
        mounted.session.connection.conversations["conv_b"] != nil
      }
      group.select(chat.id)
      try await pause(mounted.screen, .milliseconds(300))
      return mounted
    }

    /// What renders when `sessionID`'s row arrives with a new preview and time.
    private func renders(_ mounted: Mounted, whenRowChanges sessionID: String) throws -> [String:
      Int]
    {
      let list = mounted.session.connection.sessionList
      var row = try #require(list.session(sessionID))
      row.preview = "Changed"
      row.updatedAt += 100
      return RenderTally.recording {
        list.apply(.upsert(sessions: [row]))
        mounted.screen.settle(0)
      }
    }

    @Test("Another session's row renders the sidebar, not the window or the open chats")
    func anotherSessionsRowRendersTheSidebarOnly() async throws {
      let mounted = try await mountedWithSideChat()
      defer { mounted.screen.close() }
      let renders = try renders(mounted, whenRowChanges: "conv_c")
      #expect(renders == ["sidebar": 1], "\(renders)")
    }

    @Test("A hidden tab's session renders that tab, not the window or the shown chat")
    func aKeptTabsRowRendersItsTab() async throws {
      let mounted = try await mountedWithSideChat()
      defer { mounted.screen.close() }
      let renders = try renders(mounted, whenRowChanges: "conv_b")
      #expect(renders["shell"] == nil, "\(renders)")
      #expect(renders["tab"] == 1, "\(renders)")
      #expect(renders["screen"] == 1, "\(renders)")
    }

    @Test("The shown session's row renders its chat and the sidebar, not the window")
    func theShownSessionsRowRendersItsChat() async throws {
      let mounted = try await mountedWithSideChat()
      defer { mounted.screen.close() }
      let renders = try renders(mounted, whenRowChanges: "conv_a")
      #expect(renders["shell"] == nil, "\(renders)")
      #expect(renders["sidebar"] == 1, "\(renders)")
    }

    @Test("The shown session's new title renders the strip in the titlebar, not the window")
    func aTitleRendersTheStrip() async throws {
      let session = try await signedInSession(threeSessionServer())
      let screen = try await titledWindow(session, page: .session("conv_a"))
      defer { screen.close() }
      let list = session.connection.sessionList
      var row = try #require(list.session("conv_a"))
      row.title = "Renamed"
      let renders = RenderTally.recording {
        list.apply(.upsert(sessions: [row]))
        screen.settle(0.2)
      }
      #expect(renders["strip"] == 1, "\(renders)")
      #expect(renders["shell"] == nil, "\(renders)")
    }
  }
#endif
