import XCTest

/// A session's files and right panel on the local server's fixture session, whose workspace is
/// seeded with README.md, docs/, src/ and notes.
final class MacWorkspaceFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// One click on a file in the tree opens it in the viewer.
  @MainActor
  func testSingleClickOpensAFile() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)
    live.click(live.element("inspector-tab-files", in: app), "the Files tab")

    live.click(live.element("workspace.tree.row.README.md", in: app), "README.md", timeout: 30)
    XCTAssertTrue(
      live.element("workspace.viewer", in: app).appears(within: 20),
      "one click did not open the file")
  }

  /// The Changes tab lists the session's changes, or says there are none.
  @MainActor
  func testChangesTabShowsTheChangesList() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)

    live.click(live.element("inspector-tab-changes", in: app), "the Changes tab")
    XCTAssertTrue(
      live.element("workspace.changes", in: app).appears(within: 20), "no changes list")
  }

  /// Every section the right panel offers shows its own content.
  @MainActor
  func testInspectorShowsEverySection() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)

    let sections = [
      ("files", live.element("workspace.tree", in: app)),
      ("changes", live.element("workspace.changes", in: app)),
      ("info", live.text(containing: "Session ID", in: app)),
    ]
    for (section, content) in sections {
      live.click(live.element("inspector-tab-\(section)", in: app), "the \(section) tab")
      XCTAssertTrue(content.appears(within: 20), "the \(section) section shows nothing")
    }
    for section in ["pullRequests", "agents"] {
      let tab = live.element("inspector-tab-\(section)", in: app)
      if tab.exists { tab.click() }
      live.assertRunning(app, "on the \(section) section")
    }
  }

  /// The tree's filter narrows the files to the matching ones.
  @MainActor
  func testFileFilterNarrowsTheTree() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)
    live.click(live.element("inspector-tab-files", in: app), "the Files tab")
    let notes = live.element("workspace.tree.row.notes.md", in: app)
    XCTAssertTrue(notes.appears(within: 30), "the tree did not load")

    let filter = live.element("workspace.tree.filter", in: app)
    live.click(filter, "the filter")
    filter.typeText("README")
    XCTAssertTrue(notes.disappears(within: 15), "the filter left a file that differs")
    XCTAssertTrue(
      live.element("workspace.tree.row.README.md", in: app).appears(within: 5), "it hid the match")
  }

  /// Where the session's runner hosts its terminal, the session's chat tab carries Chat /
  /// Terminal: each side shows that view in the tab, and the click opens or closes no tab.
  @MainActor
  func testChatTabSwitchShowsTheSessionsTerminal() throws {
    let live = MacLiveUITestSupport(self)
    try live.requireTerminals()
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    let transcript = live.element("transcript-\(session)", in: app)
    XCTAssertTrue(transcript.appears(within: 15), "no chat")
    let terminalSide = live.element("tab-view-mode-terminal", in: app)
    try XCTSkipUnless(
      terminalSide.appears(within: 15), "The fixture session's runner hosts no terminal view.")

    live.click(terminalSide, "the tab's Terminal side")
    XCTAssertTrue(
      live.element("session-terminal", in: app).appears(within: 30),
      "the tab's switch did not show the session's terminal")
    XCTAssertEqual(live.tabs("chat", in: app).count, 1, "the click opened or closed a tab")
    live.shot(app, "session-chrome-tab-switch-terminal")
    live.click(live.element("tab-view-mode-chat", in: app), "the tab's Chat side")
    XCTAssertTrue(transcript.appears(within: 15), "the tab's switch did not show the chat")
    live.assertRunning(app, "after the tab's switch")
  }

  #if OMNIGENT_CHROMIUM
    /// With a browser tab focused, alone and then in a split beside the chat, the session's
    /// toolbar controls stay in the titlebar, and its toggle shows the right panel to the right
    /// of both panes, with the session's files.
    @MainActor
    func testSessionControlsAndPanelStayOverABrowserTab() throws {
      let live = MacLiveUITestSupport(self)
      let session = try live.fixtureSession()
      let app = live.launch()
      defer { app.terminate() }
      live.open(session, in: app)
      let controls = ["header-session-menu", "toggle-inspector"]
      for control in controls {
        XCTAssertTrue(live.element(control, in: app).appears(within: 15), "no \(control)")
      }
      XCTAssertFalse(
        live.element("header-project-tag", in: app).exists, "the project tag is in the toolbar")

      app.typeKey("b", modifierFlags: [.command, .option])
      let tab = live.tabs("browser", in: app).firstMatch
      XCTAssertTrue(tab.appears(within: 20), "Option-Command-B opened no browser tab")
      MacNotificationPrompts.decline(waiting: 2)
      let omnibox = live.element("browser.omnibox", in: app)
      live.click(omnibox, "the address field", timeout: 20)
      for control in controls {
        XCTAssertTrue(live.element(control, in: app).exists, "\(control) left with the chat")
      }
      // With no chat on screen, the toggle shows the session's panel and hides it again.
      let toggle = live.element("toggle-inspector", in: app)
      let panel = live.element("inspector-tabs", in: app)
      live.click(toggle, "the right-panel toggle over the browser")
      XCTAssertTrue(panel.appears(within: 10), "the toggle did not show the panel over the browser")
      live.shot(app, "session-chrome-browser-panel-open")
      live.click(toggle, "the right-panel toggle over the browser")
      XCTAssertTrue(panel.disappears(within: 10), "the toggle did not hide it over the browser")
      try panelBesideTheSplit(of: tab, session: session, controls: controls, live: live, app: app)
      live.assertRunning(app, "after the panel")
    }

    /// Puts the browser `tab` in a split beside the chat: the session's controls stay with
    /// either pane focused, and the panel opens to the right of both panes, with its files.
    @MainActor
    private func panelBesideTheSplit(
      of tab: XCUIElement, session: String, controls: [String], live: MacLiveUITestSupport,
      app: XCUIApplication
    ) throws {
      let (toggle, panel) = (
        live.element("toggle-inspector", in: app), live.element("inspector-tabs", in: app)
      )
      let omnibox = live.element("browser.omnibox", in: app)
      live.contextMenu(tab, choose: "Open in Split View", in: app)
      let divider = live.element("tab-split-divider", in: app)
      XCTAssertTrue(divider.appears(within: 15), "no split")
      XCTAssertTrue(
        live.element("transcript-\(session)", in: app).appears(within: 15), "no chat pane")
      live.focusComposer(in: app)
      live.shot(app, "session-chrome-split-chat-focused")
      live.click(omnibox, "the address field in its pane", timeout: 20)
      for control in controls {
        XCTAssertTrue(live.element(control, in: app).exists, "\(control) left in the split")
      }
      live.shot(app, "session-chrome-split-browser-focused")

      // The VM's window has room for both panes beside the panel once the sidebar hides;
      // narrower, the split shows the focused pane alone.
      let sidebar = live.element("sidebar", in: app)
      app.typeKey("s", modifierFlags: [.command, .control])
      XCTAssertTrue(sidebar.disappears(within: 10), "the sidebar did not hide")
      live.click(toggle, "the right-panel toggle")
      XCTAssertTrue(panel.appears(within: 10), "the toggle did not show the panel")
      XCTAssertTrue(divider.exists, "both panes beside the panel")
      live.click(live.element("inspector-tab-files", in: app), "the Files tab")
      XCTAssertTrue(
        live.element("workspace.tree.row.README.md", in: app).appears(within: 30),
        "the panel does not show the session's files")
      // Whichever side each pane takes, both are before the panel.
      let chat = live.element("transcript-\(session)", in: app)
      XCTAssertTrue(
        live.waitUntil { panel.frame.minX >= max(omnibox.frame.maxX, chat.frame.maxX) - 1 },
        "the panel at \(panel.frame) is not after the browser \(omnibox.frame) and chat \(chat.frame)"
      )
      XCTAssertGreaterThan(
        abs(chat.frame.midX - omnibox.frame.midX), 100, "the chat and the browser side by side")
      // The tab row's last control, Full screen, sits at the panel's trailing edge.
      let fullScreen = app.buttons.matching(
        NSPredicate(format: "identifier == 'inspector-tabs' AND label == 'Full screen'")
      ).firstMatch
      let window = app.windows.firstMatch.frame
      XCTAssertLessThan(window.maxX - fullScreen.frame.maxX, 24, "the panel at the window's edge")
      live.shot(app, "session-chrome-split-panel-open")

      live.click(omnibox, "the address field again", timeout: 10)
      live.click(toggle, "the right-panel toggle")
      XCTAssertTrue(panel.disappears(within: 10), "the toggle did not hide the panel")
    }
  #endif

  /// Typing @ offers the workspace's files, and attaching a folder puts it in the composer.
  @MainActor
  func testAtMentionAttachesAFolder() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    // A flow that stopped halfway leaves its draft, and "@" after other text offers nothing.
    clearDraft(live, in: app)
    app.typeText("@")
    XCTAssertTrue(
      live.element("composer-completions", in: app).appears(within: 20), "no completions")
    live.click(live.element("composer-completion-@src/", in: app), "the src folder", timeout: 20)
    live.click(
      live.element("composer-completion-attach-@src/model/", in: app), "Attach model", timeout: 20)
    XCTAssertTrue(
      live.element("composer-mention-src/model/", in: app).appears(within: 10),
      "the folder is not in the composer")
    // Leave the fixture's draft as it was for the next flow.
    clearDraft(live, in: app)
    XCTAssertTrue(
      live.element("composer-mention-src/model/", in: app).disappears(within: 10),
      "the folder stayed in the draft")
    XCTAssertEqual(live.composerText(in: app), "")
  }

  /// Empties the fixture session's draft: its text and the folder this flow attaches.
  @MainActor
  private func clearDraft(_ live: MacLiveUITestSupport, in app: XCUIApplication) {
    let remove = app.buttons["Remove src/model/"]
    if remove.exists { remove.click() }
    live.focusComposer(in: app)
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(.delete, modifierFlags: [])
  }

  /// Fork copies the conversation into a new session and opens it; deleting cleans up.
  @MainActor
  func testForkCopiesTheConversationIntoANewSession() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    live.contextMenu(live.row(session, in: app), choose: "Fork", in: app)
    // The sheet is found by its Clone button: a sheet's own identifier does not show on a Mac.
    live.click(live.element("fork-clone", in: app), "Clone", timeout: 15)

    let original = live.element("transcript-\(session)", in: app)
    XCTAssertTrue(original.disappears(within: 30), "the fork did not open")
    let fork = live.anyTranscript(in: app)
    XCTAssertTrue(fork.appears(within: 30), "no transcript for the fork")
    XCTAssertTrue(
      live.text(containing: "List the workspace and summarize it.", in: app)
        .appears(within: 30),
      "the fork does not have the conversation")

    let forkID = fork.identifier.replacing("transcript-", with: "")
    live.contextMenu(live.row(forkID, in: app), choose: "Delete\u{2026}", in: app)
    live.clickDialogButton("Delete", in: app)
    XCTAssertTrue(live.row(forkID, in: app).disappears(within: 15), "the fork stayed")
  }
}
