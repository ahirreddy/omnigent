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
@testable import OmnigentWorkspaceUI

/// The window's session chrome: the session's toolbar controls show and act on the session
/// whichever tab or pane has the focus, and its right panel sits at the window's trailing edge.
@MainActor
@Suite("Session chrome around the tabs", .serialized, .timeLimit(.minutes(2)))
struct SessionChromeWindowTests {
  /// A tab of each kind a session's strip holds beside its chat.
  private static let otherTabs: [(name: String, content: AppTabContent)] = [
    ("a side chat", .sideChatSession(parentID: ChromeWindow.shown, childID: ChromeWindow.sideChat)),
    ("a new side chat", .sideChatSession(parentID: ChromeWindow.shown, childID: nil)),
    ("a browser page", .browser(browserID: UUID())),
    ("a remote browser", .remoteBrowser(sessionID: ChromeWindow.shown, tabID: "tab_remote")),
    ("a terminal", .terminal(sessionID: ChromeWindow.shown, terminalID: "t1")),
    ("the New Tab page", .newTab),
  ]

  @Test("The toolbar offers the session's controls whichever kind of tab has the focus")
  func controlsForEveryTab() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    let items = window.toolbarItems
    for tab in Self.otherTabs {
      try await window.show(tab.content)
      #expect(window.tabs.selected?.content == tab.content, "\(tab.name) has the focus")
      #expect(window.sessionControls == ChromeWindow.controls, "over \(tab.name)")
      let kept = Set(window.toolbarItems)
      #expect(items.allSatisfy(kept.contains), "\(tab.name) replaced a toolbar item")
    }
    window.tabs.select(window.chatTabID)
    try await pause(window.screen, .milliseconds(300))
    #expect(window.sessionControls == ChromeWindow.controls, "back on the chat")
    #expect(window.toolbarItems == items, "the same items as before the tabs opened")
  }

  @Test("The switch on the session's chat tab shows the chat or the agent's terminal in that tab")
  func viewSwitchOnTheChatTab() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    #expect(window.session.tabs.viewMode(ChromeWindow.shown) == .chat)
    try window.click(mode: .terminal)
    #expect(window.session.tabs.viewMode(ChromeWindow.shown) == .terminal)
    #expect(window.tabs.selectedID == window.chatTabID, "the click selects no other tab")
    try window.click(mode: .chat)
    #expect(window.session.tabs.viewMode(ChromeWindow.shown) == .chat)
    #expect(window.tabs.tabs.count == 1, "and closes, opens or drags none")

    // From another tab, a side shows the chat in that view; the shown side answers too.
    let page = try await window.show(.browser(browserID: UUID()))
    try window.click(mode: .chat)
    #expect(window.tabs.selectedID == window.chatTabID, "Chat shows the chat")
    window.tabs.select(page.id)
    try await pause(window.screen, .milliseconds(200))
    try window.click(mode: .terminal)
    #expect(window.session.tabs.viewMode(ChromeWindow.shown) == .terminal)
    #expect(window.tabs.selectedID == window.chatTabID, "the chat comes to the front")

    window.tabs.select(page.id)
    try await pause(window.screen, .milliseconds(200))
    let toggleMode = try #require(window.probe.commands?.toggleViewMode, "the menu's command")
    toggleMode()
    window.screen.settle(0.3)
    #expect(window.session.tabs.viewMode(ChromeWindow.shown) == .chat)
    #expect(window.tabs.selectedID == window.chatTabID)
  }

  @Test("From a terminal tab, the session menu and Share act on the window's session")
  func menuAndShareFromATerminalTab() async throws {
    let window = try await ChromeWindow.open()
    defer {
      window.screen.close()
      SystemSideEffects.reset()
    }
    try await window.show(.terminal(sessionID: ChromeWindow.shown, terminalID: "t1"))
    #expect(!window.toolbarLabels.contains("Show Chat"), "a terminal adds no item of its own")

    try window.chooseInSessionMenu("Mark as unread")
    try await settle(window.screen, until: "the session marked unread") {
      window.list.unreadIDs.contains(ChromeWindow.shown)
    }

    // The project tag is gone from the toolbar: the session menu files the session.
    #expect(!window.hasControl("header-project-tag"))
    try window.chooseInSessionMenu("Alpha")
    let movedToProject = {
      window.server.requests("PATCH", "/v1/sessions/\(ChromeWindow.shown)").contains { request in
        request.body.flatMap { String(bytes: $0, encoding: .utf8) }?.contains("p1") == true
      }
    }
    try await settle(window.screen, until: "the move to the project", movedToProject)
    #expect(movedToProject(), "the session menu's Add to project files the session")

    try window.click(control: ChromeWindow.share)
    try await settle(window.screen, until: "the Share sheet") {
      window.screen.window.attachedSheet != nil
    }
    let share = try #require(window.chrome.shareStore, "the session's sharing, read by the window")
    #expect(share.sessionID == ChromeWindow.shown)
  }

  @Test("From a side chat, the controls and the panel are the session's, not the side chat's")
  func sessionOverASideChat() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    try await window.show(
      .sideChatSession(parentID: ChromeWindow.shown, childID: ChromeWindow.sideChat))
    try await settle(window.screen, until: "the side chat") {
      window.session.connection.conversations[ChromeWindow.sideChat] != nil
    }
    #expect(window.sessionControls == ChromeWindow.controls, "Share is the session's")

    try window.click(control: ChromeWindow.panelToggle)
    try await settle(window.screen, untilShowing: "alpha-notes.txt")
    #expect(try !window.screen.shows("beta-notes.txt"), "the side chat's workspace is not shown")
    #expect(window.panelSplits == 1, "the side chat brings no panel of its own")

    // The side chat's own Toggle Right Panel reaches the window's panel.
    let toggle = try #require(window.probe.commands?.toggleInspector, "the chat's command")
    toggle()
    window.screen.settle(0.3)
    #expect(!window.chrome.panel.isShown)

    try window.chooseInSessionMenu("Mark as unread")
    try await settle(window.screen, until: "the session marked unread") {
      !window.list.unreadIDs.isEmpty
    }
    #expect(window.list.unreadIDs == [ChromeWindow.shown], "the session, not the side chat")
  }

  @Test("In a split, the switch changes the chat beside the focused pane and leaves the focus")
  func viewSwitchInASplit() async throws {
    let window = try await ChromeWindow.open(width: 1_600)
    defer { window.screen.close() }
    let page = try await window.show(.browser(browserID: UUID()))
    try await window.split(with: page, focus: .trailing)

    try window.click(mode: .terminal)
    #expect(window.session.tabs.viewMode(ChromeWindow.shown) == .terminal)
    #expect(window.tabs.selectedID == page.id, "the browser's pane keeps the focus")
    #expect(window.tabs.splitState?.focused == .trailing)
  }

  @Test("Export from the session menu over a page says when the transcript can't be read")
  func exportFailureAlerts() async throws {
    let window = try await ChromeWindow.open()
    defer {
      window.screen.close()
      SystemSideEffects.reset()
    }
    try await window.show(.newTab)
    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    try window.chooseInSessionMenu("Export\u{2026}")
    try await settle(window.screen, until: "the alert") {
      SystemSideEffects.record.alertMessages.contains { $0.contains("Something Went Wrong") }
    }
    try await settle(window.screen, until: "OK to clear it") {
      window.chrome.failures.messages.isEmpty
    }
  }
}
