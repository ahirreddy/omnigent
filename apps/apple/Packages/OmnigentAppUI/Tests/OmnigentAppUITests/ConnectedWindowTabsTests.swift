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
    try await pause(mounted.screen, .milliseconds(100))
    let framesBefore = mounted.screen.controlFrames
    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    group.closingShell = shell.id
    let message = "The shell could not be closed"
    try await settle(mounted.screen, untilShowing: message, contains: true)

    // The banner's only control is the one it added, and it pushes the page below it down.
    let dismiss = try #require(
      mounted.screen.controlFrames.first { !framesBefore.contains($0) },
      "\(mounted.screen.controlFrames)")
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
