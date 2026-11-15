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

/// The window's right panel: one column at the trailing edge, beside every pane, showing the
/// session's workspace whichever tab has the focus.
extension SessionChromeWindowTests {
  @Test("From a browser tab, the right-panel toggle shows the session's files at the trailing edge")
  func panelFromABrowserTab() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    try await window.show(.browser(browserID: UUID()))
    #expect(window.panelColumn == nil, "the panel starts hidden")

    try window.click(control: ChromeWindow.panelToggle)
    #expect(window.chrome.panel.isShown)
    try await settle(window.screen, untilShowing: "alpha-notes.txt")
    try await window.settleUntilPanelOpen()
    let panel = try window.panelFrame()
    #expect(panel.maxX == window.screen.host.bounds.maxX, "at the window's trailing edge: \(panel)")
    #expect(window.panelSplits == 1, "one panel for the window, none per tab")
    let stored = window.preferences.string(forKey: InterfacePreferences.workspacePanelKey)
    #expect(stored == WorkspacePanelDefault.open.rawValue, "showing it is the next chat's default")

    // Option-Command-] is the toolbar button's own shortcut.
    let handled = try pressShortcut(
      window.screen, keyCode: 30, characters: "]", modifiers: [.command, .option])
    #expect(handled, "the toggle's shortcut answers from a browser tab")
    // Offscreen, SwiftUI's split view reports the column expanded again once it closes over a
    // tab with no chat on screen; MacWorkspaceFlowUITests sees it close in the app.
    #expect(!window.chrome.panel.isShown)

    // Toggle Right Panel in the Conversation menu, which no conversation answers here.
    let toggle = try #require(window.probe.commands?.toggleInspector, "the menu's command")
    toggle()
    #expect(window.chrome.panel.isShown)
  }

  @Test("With a file of the session open in the panel, the controls stay and the toggle hides it")
  func fileOpenInThePanel() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    let page = try await window.show(.browser(browserID: UUID()))
    try window.click(control: ChromeWindow.panelToggle)
    try await settle(window.screen, untilShowing: "alpha-notes.txt")
    // As the file's row in the panel opens it.
    let workspace = try #require(window.session.workspace(of: ChromeWindow.shown))
    await workspace.open(.file(path: "alpha-notes.txt", line: nil))
    try await settle(window.screen, untilShowing: "two", contains: true)
    #expect(window.sessionControls == ChromeWindow.controls, "with the panel's file open")
    #expect(window.tabs.selectedID == page.id, "the browser's tab is still the shown one")
    #expect(try window.panelFrame().maxX == window.screen.host.bounds.maxX)

    try window.click(control: ChromeWindow.panelToggle)
    // Offscreen, SwiftUI's split view reports the column expanded again once it closes over a
    // tab with no chat on screen; MacWorkspaceFlowUITests sees it close in the app.
    #expect(!window.chrome.panel.isShown)
  }

  // Where each pane sits beside the panel is read from the real app's accessibility frames in
  // MacWorkspaceFlowUITests; SwiftUI keeps the panes' markers from an offscreen window.
  @Test("In a split, the panel is one column at the trailing edge whichever pane has the focus")
  func panelBesideBothPanes() async throws {
    let window = try await ChromeWindow.open(width: 1_600)
    defer { window.screen.close() }
    let page = try await window.show(.browser(browserID: UUID()))
    try await window.split(with: page, focus: .trailing)
    #expect(window.sessionControls == ChromeWindow.controls, "with the browser's pane focused")

    try window.click(control: ChromeWindow.panelToggle)
    try await settle(window.screen, untilShowing: "alpha-notes.txt")
    try await window.settleUntilPanelOpen()
    for focus in [TabPane.trailing, .leading] {
      window.tabs.focus(focus)
      try await settle(window.screen, until: "the panel with \(focus) focused") {
        let column = window.panelColumn
        let maxX = column.map { $0.convert($0.bounds, to: window.screen.host).maxX }
        return maxX == window.screen.host.bounds.maxX && window.panelSplits == 1 && window.sessionControls == ChromeWindow.controls
          && (try? window.screen.shows("alpha-notes.txt")) == true
      }
      let panel = try window.panelFrame()
      #expect(panel.maxX == window.screen.host.bounds.maxX, "\(focus): \(panel)")
      #expect(window.panelSplits == 1, "\(focus): the window's one panel, no pane's own")
      #expect(window.sessionControls == ChromeWindow.controls, "with \(focus) focused")
      #expect(try window.screen.shows("alpha-notes.txt"))
    }

    window.tabs.focus(.trailing)
    try await pause(window.screen, .milliseconds(200))
    try window.click(control: ChromeWindow.panelToggle)
    #expect(!window.chrome.panel.isShown, "the toggle hides it from the browser's pane")
    try await window.settleUntilPanelClosed()
  }

  @Test("With the chat alone, the panel is at the trailing edge and follows the session")
  func panelInASinglePane() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    try window.click(control: ChromeWindow.panelToggle)
    try await settle(window.screen, untilShowing: "alpha-notes.txt")
    try await window.settleUntilPanelOpen()
    let panel = try window.panelFrame()
    #expect(panel.maxX == window.screen.host.bounds.maxX, "\(panel)")

    // Another session has its own panel state: this one's stays open for when it is back.
    window.session.tabs.show(.session("conv_c"))
    try await pause(window.screen, .milliseconds(400))
    window.session.tabs.chrome("conv_c").panel.isShown = false
    try await pause(window.screen, .milliseconds(100))
    try await window.settleUntilPanelClosed("for the other session, by its own choice")
    window.session.tabs.show(.session(ChromeWindow.shown))
    try await window.settleUntilPanelOpen("as this session left it")
    #expect(try window.panelFrame().maxX == window.screen.host.bounds.maxX)
  }

  @Test("With its chat focused, the chat's own menu commands reach the window's panel")
  func chatCommandsReachTheWindowsPanel() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    let openChanges = try #require(window.probe.commands?.openChanges, "the chat's command")
    openChanges()
    try await window.settleUntilPanelOpen()
    try await settle(window.screen, until: "the changes tab") {
      window.chrome.inspectorTab == .changes
    }
    #expect(window.chrome.inspectorTab == .changes)
    #expect(try window.panelFrame().maxX == window.screen.host.bounds.maxX)
    #expect(window.panelSplits == 1, "the window's panel, and none of the chat's own")
  }

  @Test("The window reads the panel's pull requests, and again when a turn ends, over any tab")
  func pullRequestsFollowTheSession() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    try await settle(window.screen, until: "the pull requests") {
      !window.server.requests("GET", ChromeWindow.pullRequests).isEmpty
    }
    try await pause(window.screen, .milliseconds(300))
    let atOpen = window.server.requests("GET", ChromeWindow.pullRequests).count
    #expect(atOpen == 1, "the window reads them once, the chat inside not at all: \(atOpen)")
    try await window.show(.newTab)
    let read = window.server.requests("GET", ChromeWindow.pullRequests).count
    #expect(read == atOpen, "a tab switch reads them no more: \(read)")
    let store = try #require(window.session.connection.conversations[ChromeWindow.shown])
    for status in [OmnigentCoreFFI.TurnStatus.running, .idle] {
      var header =
        store.header
        ?? OmnigentCoreFFI.SessionHeader(
          id: ChromeWindow.shown, title: "", status: .idle, readOnly: false, archived: false,
          permissionLevel: nil, failureMessage: nil, settings: nil)
      header.status = status
      store.apply(
        revision: store.revision + 1,
        change: TranscriptChange(rows: [], header: header, sections: nil))
      try await pause(window.screen, .milliseconds(200))
    }
    try await settle(window.screen, until: "the pull requests after the turn") {
      window.server.requests("GET", ChromeWindow.pullRequests).count == read + 1
    }
  }

  @Test("A page without a session shows no session controls and no panel")
  func noChromeOverAPage() async throws {
    let window = try await ChromeWindow.open()
    defer { window.screen.close() }
    try window.click(control: ChromeWindow.panelToggle)
    try await window.settleUntilPanelOpen()
    window.session.tabs.show(.usage)
    try await settle(window.screen, until: "the page without session chrome") {
      window.sessionControls.isEmpty && !window.session.tabs.shownPanelIsShown
        && window.probe.commands == nil
    }
    #expect(window.sessionControls.isEmpty, "\(window.toolbarLabels)")
    #expect(!window.session.tabs.shownPanelIsShown, "a page has no panel to show")
    #expect(window.probe.commands == nil, "no session answers the Conversation menu")
    window.session.tabs.show(.session(ChromeWindow.shown))
    try await settle(window.screen, until: "the session's chrome") {
      window.sessionControls == ChromeWindow.controls && window.chrome.panel.isShown
    }
    #expect(window.sessionControls == ChromeWindow.controls)
    #expect(window.chrome.panel.isShown, "the page left the session's own choice alone")
    try await window.settleUntilPanelOpen("the session's panel, back as it was")
  }
}
