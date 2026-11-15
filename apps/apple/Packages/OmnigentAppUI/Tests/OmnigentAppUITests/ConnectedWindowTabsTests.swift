import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentUIComponents

/// What the mounted window does with its tabs: their failures and their menus.
extension ConnectedWindowFlowTests {
  @Test("A shell that can't be closed shows a banner, and Dismiss clears it")
  func tabFailureBanner() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a/resources/terminals/t1", method: "DELETE",
      .json(#"{"detail":"no"}"#, status: 500))
    let mounted = try await mounted(server)
    defer {
      mounted.screen.close()
      SystemSideEffects.reset()
    }
    try await settle(mounted.screen, until: "the terminals") {
      mounted.session.terminalStores["conv_a"] != nil
    }
    let group = mounted.session.tabs.group("conv_a")
    let shell = group.open(.terminal(sessionID: "conv_a", terminalID: "t1"), title: "zsh")
    group.select(group.tabs[0].id)
    let framesBefore = try await settledControlFrames(mounted.screen)
    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    group.closingShell = shell.id
    let message = "The shell could not be closed"
    try await settle(mounted.screen, untilShowing: message, contains: true)
    // The banner's only control is the one it added, and it pushes the page below it down.
    let frames = try await settledControlFrames(mounted.screen)
    let dismiss = try #require(frames.first { !framesBefore.contains($0) }, "\(frames)")
    try mounted.screen.click(CGPoint(x: dismiss.midX, y: dismiss.midY))
    try await settle(mounted.screen, until: "the banner to go") {
      (try? mounted.screen.shows(message)) == false
    }
  }

  @Test("A chat tab's Rename Session asks for a title and renames the session")
  func renamingFromATab() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a", method: "PATCH",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"title":"Renamed"}"#))
    let mounted = try await mounted(server)
    defer {
      mounted.screen.close()
      SystemSideEffects.reset()
    }
    let list = mounted.session.connection.sessionList
    try await settle(mounted.screen, until: "the list") { list.session("conv_a") != nil }
    let tabs = mounted.session.tabs
    let chat = try #require(tabs.group("conv_a").tabs.first)

    mounted.model.askToRename(tabID: "tab_missing", tabs: tabs, list: list)
    #expect(mounted.model.renamingFromTab == nil, "a closed tab asks nothing")

    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    mounted.model.askToRename(tabID: chat.id, tabs: tabs, list: list)
    #expect(mounted.model.renameText == list.session("conv_a")?.title)
    mounted.model.renameText = "Renamed"
    try await settle(mounted.screen, until: "the rename") {
      !server.requests("PATCH", "/v1/sessions/conv_a").isEmpty
    }
  }

  @Test("Rename Session on a chat's row in the tab overview closes it and renames the session")
  func renamingFromTheOverview() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a", method: "PATCH",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"title":"Renamed"}"#))
    let mounted = try await mounted(server)
    let list = mounted.session.connection.sessionList
    try await settle(mounted.screen, until: "the list") { list.session("conv_a") != nil }
    // The overview as the window presents it, over the window's own tabs and rename.
    let overview = OffscreenWindow(
      TabOverviewHost(view: mounted.view), width: 600, height: 600)
    defer {
      overview.close()
      mounted.screen.close()
    }
    try await settle(overview, until: "the overview") { overview.window.attachedSheet != nil }

    // The rename prompt is the connected window's; its Rename button answers it.
    SystemSideEffects.answer(alert: .alertFirstButtonReturn, for: mounted.screen.window)
    // The chat's row follows the list's own first row.
    let menu = try contextMenu(ofListRow: 1, in: overview)
    let rename = try #require(menu.items.firstIndex { $0.title == "Rename Session\u{2026}" })
    menu.performActionForItem(at: rename)
    // The prompt opens on the session's title.
    #expect(mounted.model.renamingFromTab?.id == "conv_a")
    #expect(mounted.model.renameText == list.session("conv_a")?.title)
    mounted.model.renameText = "Renamed"
    try await settle(overview, until: "the overview to close") {
      overview.window.attachedSheet == nil
    }
    try await settle(mounted.screen, until: "the rename") {
      !server.requests("PATCH", "/v1/sessions/conv_a").isEmpty
    }
    #expect(try server.patched("/v1/sessions/conv_a").first?["title"] as? String == "Renamed")
  }

  #if DEBUG
    @Test("Switching to a chat that stayed built renders it once")
    func switchingRendersTheShownChatOnce() async throws {
      let mounted = try await mounted()
      defer { mounted.screen.close() }
      let group = mounted.session.tabs.group("conv_a")
      let chat = try #require(group.tabs.first)
      group.open(.sideChatSession(parentID: "conv_a", childID: "conv_b"))
      try await settle(mounted.screen, until: "the side chat") {
        mounted.session.connection.conversations["conv_b"] != nil
      }
      try await pause(mounted.screen, .milliseconds(300))

      let renders = RenderTally.recording {
        group.select(chat.id)
        mounted.screen.settle(0)
      }
      #expect(renders["screen"] == 1, "\(renders)")
    }
  #endif

  @Test("A remote tab that ended opens again in its place")
  func reopeningARemoteTab() async throws {
    let connection = try await signedInStore(threeSessionServer())
    let session = ServerSession(
      connection: connection, remoteBrowser: FixtureRemoteBrowser(latency: .milliseconds(1)))
    let selection = WindowSelection(.session("conv_a"))
    let view = ConnectedServerView(
      session: session, selection: selection.binding, sidebar: SidebarModel(),
      opener: ExternalURLOpener { _ in true }, openInNewWindow: nil, serverSwitching: nil)
    let group = session.tabs.group("conv_a")
    session.tabs.show(.session("conv_a"))
    let ended = group.open(.remoteBrowser(sessionID: "conv_a", tabID: "tab_old"))
    let reopen = view.reopenRemoteBrowser(ended, sessionID: "conv_a", routes: view.windowTabs)
    reopen(
      "https://example.com", RemoteBrowserTabRecord(url: "https://example.com", profile: "work"))
    try await eventually("the new tab") {
      guard case .remoteBrowser(_, let id) = group.tab(ended.id)?.content else { return false }
      return id != "tab_old"
    }
    #expect(group.tabs.count == 2, "its chat, and the tab in its old place")
  }
}

/// The window's tab overview, shown, as `view` presents it: its tabs and its Rename Session.
private struct TabOverviewHost: View {
  let view: ConnectedServerView
  @State private var isPresented = true

  var body: some View {
    Color.clear.modifier(
      WindowTabOverview(
        tabs: view.windowTabs, isPresented: $isPresented,
        renameSession: view.renameSessionOfTab))
  }
}
