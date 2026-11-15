#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  private struct ChromeTab: Identifiable {
    let id: String
  }

  /// A window's session and tabs, changed from the test.
  @MainActor
  @Observable
  private final class ChromeModel {
    var shownID = "chat"
    var split: TabSplitState?
    var hasSession = true
    var showsInspector = false
    var inspectorTab = InspectorTab.files
    var mode = SessionViewMode.chat
    var fork: ForkViewState?
    /// The room the window's toolbar items ask the titlebar's tabs to leave.
    @ObservationIgnored var trailingItems: Int?
    /// The commands the menus would run.
    @ObservationIgnored var commands: SessionCommandActions?
    /// What the session's controls and the hosted chat asked the host to do.
    @ObservationIgnored var log: [String] = []
  }

  private struct ChromeCommandsProbe: View {
    let model: ChromeModel
    @FocusedValue(\.sessionCommands) private var commands

    var body: some View {
      model.commands = commands
      return Color.clear.frame(width: 1, height: 1)
    }
  }

  /// The session as the window and its chat show it.
  @MainActor
  private enum ChromeSession {
    static var state: ConversationViewState {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")],
        sections: [EventSection(id: "presence", title: "Viewers", summary: "")],
        terminal: .ready)
      state.summary = SessionSummary(id: "session-1", title: "A session")
      return state
    }
  }

  /// The session's chat, which makes its bindings in its own body as the app's chat does: a
  /// window that renders again passes it nothing new.
  private struct HostedChat: View {
    @Bindable var model: ChromeModel
    @State private var ownPanel = false
    @State private var draft = ""

    /// The chat inside the window's chrome reaches the window's panel through its host.
    private var extras: ConversationExtras {
      let model = model
      var extras = ConversationExtras()
      extras.showPanelTab = { model.log.append("show \($0.rawValue)") }
      return extras
    }

    var body: some View {
      ConversationScreen(
        state: ChromeSession.state, composer: ComposerViewState(), draft: $draft,
        showsInspector: $ownPanel, mode: $model.mode, actions: ConversationActions(),
        composerActions: ComposerActions(send: {}), extras: extras
      ) {
        Text("the terminal surface")
      }
    }
  }

  /// A chat tab and a page tab under one session chrome, as a Mac window lays them out.
  private struct ChromeHost: View {
    @Bindable var model: ChromeModel
    /// The window keeps one tracker, as the app's shell does.
    @State private var tracker = TabDragTracker()

    private var extras: ConversationExtras {
      let model = model
      var extras = ConversationExtras(
        slots: .filled, share: (ShareViewState(), ShareActions()),
        forkActions: ForkActions(forkWith: { _ in }, cancel: {}),
        menuContext: SessionMenuContext(
          projects: [SessionProject(id: "p1", name: "Work", sessionIds: [])]),
        exportTranscript: { model.log.append("export") },
        shareOpened: { model.log.append("share opened") })
      extras.sessionActions.setUnread = { session, _ in model.log.append("unread \(session.id)") }
      extras.sessionActions.moveToProject = { session, project in
        model.log.append("move \(session.id) to \(project?.name ?? "no project")")
      }
      return extras
    }

    private var chrome: SessionChrome {
      SessionChrome(
        state: ChromeSession.state, extras: extras, actions: ConversationActions(),
        mode: $model.mode,
        showsInspector: $model.showsInspector, inspectorTab: $model.inspectorTab,
        fork: $model.fork)
    }

    var body: some View {
      NavigationStack {
        TabSplitView(
          ["chat", "page"].map(ChromeTab.init(id:)), shownID: model.shownID, split: model.split,
          actions: TabActions()
        ) { tab in
          if tab.id == "chat" {
            HostedChat(model: model)
          } else {
            Text("a page").frame(maxWidth: .infinity, maxHeight: .infinity)
              .titlebarTrailingItems(1)
          }
        }
        .sessionChrome(model.hasSession ? chrome : nil)
        .environment(\.tabsInTitlebar, true)
        .onPreferenceChange(TitlebarTrailingItems.self) { model.trailingItems = $0 }
        .background { ChromeCommandsProbe(model: model) }
      }
      .environment(tracker)
      .environment(\.flattensGlass, true)
    }
  }

  /// The session's toolbar controls and right panel around a window's tabs.
  @Suite("Session chrome around the tabs", .serialized)
  @MainActor
  struct SessionChromeTests {
    /// The trailing cluster: no viewers, no project tag, and no switch, which the tab carries.
    private static let controls = ["Session", "Share", "Right panel"]
    /// The toolbar's buttons by their identifiers, which AppKit's own button items label.
    private static let labels = ["header-share": "Share", "toggle-inspector": "Right panel"]

    init() {
      SystemSideEffects.reset()
    }

    private func window(_ model: ChromeModel, width: CGFloat = 1_200) async throws
      -> OffscreenWindow<AnyView>
    {
      let screen = OffscreenWindow(AnyView(ChromeHost(model: model)), width: width, height: 600)
      let frame = screen.window.frame
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.window.setFrame(frame, display: false)
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      try await letOpeningEnd(screen)
      // The toolbar places its items in the first layout pass after the window has them.
      screen.window.setContentSize(CGSize(width: screen.window.frame.width, height: 601))
      try await letTasksRun(screen, milliseconds: 300)
      return screen
    }

    private func labels(_ screen: OffscreenWindow<AnyView>) -> [String] {
      (screen.window.toolbar?.visibleItems ?? []).map(\.label).filter { !$0.isEmpty }
    }

    /// Where the toolbar control with an accessibility identifier is, from the top left of
    /// the window's content.
    private func frame(of identifier: String, in screen: OffscreenWindow<AnyView>) throws
      -> CGRect
    {
      if let label = Self.labels[identifier],
        let view = screen.window.toolbar?.visibleItems?.first(where: { $0.label == label })?.view
      {
        return view.convert(view.bounds, to: screen.host)
      }
      return try screen.withAccessibilityTree {
        var pending: [Any] = (screen.window.toolbar?.visibleItems ?? []).compactMap(\.view)
        var seen = Set<ObjectIdentifier>()
        while let node = pending.popLast() {
          guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted,
            let element = object as? any NSAccessibilityProtocol & NSObject
          else { continue }
          if element.accessibilityIdentifier() == identifier {
            let inWindow = screen.window.convertFromScreen(element.accessibilityFrame())
            return screen.host.convert(inWindow, from: nil)
          }
          pending.append(contentsOf: element.accessibilityChildren() ?? [])
        }
        throw OffscreenWindowError.notFound("\(identifier) in the toolbar")
      }
    }

    private func click(_ identifier: String, in screen: OffscreenWindow<AnyView>) throws {
      let frame = try frame(of: identifier, in: screen)
      try screen.click(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func sessionMenu(_ screen: OffscreenWindow<AnyView>) throws -> NSMenu {
      let frame = try frame(of: "header-session-menu", in: screen)
      return try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The right panel's column while it shows.
    private func panel(_ screen: OffscreenWindow<AnyView>) -> CGRect? {
      let splits = screen.allViews.compactMap { $0 as? NSSplitView }
      let shown = splits.first {
        $0.arrangedSubviews.count == 2 && !$0.isSubviewCollapsed($0.arrangedSubviews[1])
      }
      return shown.map { $0.arrangedSubviews[1] }.map { $0.convert($0.bounds, to: screen.host) }
    }

    @Test("The session's controls stay in the toolbar whichever tab or pane has the focus")
    func controlsForEveryFocus() async throws {
      let model = ChromeModel()
      let screen = try await window(model)
      defer { screen.close() }
      #expect(labels(screen) == Self.controls, "no viewers, project tag or switch")
      let items = (screen.window.toolbar?.items ?? []).map(ObjectIdentifier.init)
      // The session menu, Share and the right-panel toggle, a button's width each, and the
      // group's margins.
      #expect(model.trailingItems == 4, "the chat reports none of its own")

      model.shownID = "page"
      try await letTasksRun(screen, milliseconds: 200)
      #expect(labels(screen) == Self.controls, "over a page")
      #expect(model.trailingItems == 5, "the session's, and the page's own")

      model.split = TabSplitState(leadingID: "chat", trailingID: "page", focused: .trailing)
      try await letTasksRun(screen, milliseconds: 200)
      #expect(labels(screen) == Self.controls, "with the page's pane focused")
      #expect((screen.window.toolbar?.items ?? []).map(ObjectIdentifier.init) == items)
      #expect(screen.window.title == "A session", "the chat's tab names the window")
    }

    @Test("The panel shows the session's files at the trailing edge, beside both panes")
    func panelAtTheTrailingEdge() async throws {
      let model = ChromeModel()
      model.shownID = "page"
      let screen = try await window(model)
      defer { screen.close() }
      #expect(panel(screen) == nil)

      try click("toggle-inspector", in: screen)
      #expect(model.showsInspector, "the toggle answers over a page")
      try await letTasksRun(screen, milliseconds: 300)
      #expect(try screen.shows("files slot"))
      let single = try #require(panel(screen))
      #expect(single.maxX == screen.host.bounds.maxX, "\(single)")

      model.split = TabSplitState(leadingID: "chat", trailingID: "page", focused: .trailing)
      try await letTasksRun(screen, milliseconds: 300)
      let beside = try #require(panel(screen))
      #expect(beside.maxX == screen.host.bounds.maxX, "\(beside)")
      let panels = screen.allViews.compactMap { $0 as? NSSplitView }.count
      #expect(panels == 1, "one panel for the window; the chat inside has none")
      #expect(try screen.shows("a page") && screen.shows("files slot"))

      // Option-Command-] is the toggle's own shortcut.
      try screen.press(keyCode: 30, characters: "]", modifiers: [.command, .option])
      #expect(!model.showsInspector)
    }

    @Test("Over a page the session menu moves, marks and switches the session, and Share opens")
    func controlsAct() async throws {
      let model = ChromeModel()
      model.shownID = "page"
      let screen = try await window(model)
      defer { screen.close() }

      try screen.choose("Mark as unread", in: try sessionMenu(screen))
      try screen.choose("Export\u{2026}", in: try sessionMenu(screen))
      // The project tag's choices are the menu's Add to project.
      let menu = try sessionMenu(screen)
      #expect(menu.item(named: "Add to project")?.submenu?.item(named: "Work") != nil)
      try screen.choose("Work", in: menu)
      #expect(model.log == ["unread session-1", "export", "move session-1 to Work"])

      // The tab carries the switch; the menu keeps it for a strip that is folded away.
      try screen.choose("Terminal", in: try sessionMenu(screen))
      #expect(model.mode == .terminal)
      try screen.choose("Chat", in: try sessionMenu(screen))
      #expect(model.mode == .chat)

      try click("header-share", in: screen)
      try await letTasksRun(screen, milliseconds: 200)
      #expect(screen.window.attachedSheet != nil, "the Share sheet")
      #expect(model.log.last == "share opened")
    }

    @Test("A chat inside the chrome answers the menus through the window's panel")
    func hostedChatCommands() async throws {
      let model = ChromeModel()
      let screen = try await window(model)
      defer { screen.close() }
      let commands = try #require(model.commands)
      commands.openChanges?()
      #expect(model.log == ["show changes"], "the window's panel, not one of the chat's own")
      #expect(panel(screen) == nil, "the chat shows no panel")
    }

    @Test("A page without a session has no controls, no panel and no fork")
    func noSession() async throws {
      let model = ChromeModel()
      model.showsInspector = true
      let screen = try await window(model)
      defer { screen.close() }
      #expect(panel(screen) != nil)

      model.hasSession = false
      model.shownID = "page"
      try await letTasksRun(screen, milliseconds: 300)
      #expect(labels(screen).isEmpty)
      #expect(panel(screen) == nil)
      #expect(model.trailingItems == 1, "the page's own")
      #expect(try screen.shows("a page"))
    }

    @Test("The session menu's Fork shows its dialog over any tab")
    func forkSheet() async throws {
      let model = ChromeModel()
      model.shownID = "page"
      let screen = try await window(model)
      defer { screen.close() }
      #expect(screen.window.attachedSheet == nil)
      model.fork = ForkViewState(
        id: "f", kind: .anotherDirectory, agents: [], agentID: "", directory: "/work")
      try await letTasksRun(screen, milliseconds: 300)
      #expect(screen.window.attachedSheet != nil)
    }

    #if DEBUG
      @Test("Showing the panel renders no chat kept behind a page")
      func hiddenChatStaysAsItIs() async throws {
        // The chat shows first, then is kept behind the page, as a chat the user left is.
        let model = ChromeModel()
        let screen = try await window(model)
        defer { screen.close() }
        model.shownID = "page"
        // The switch has settled once a stretch of the run loop renders nothing.
        let isQuiet = try await waitUntil(screen) {
          RenderTally.recording { screen.settle(0.3) }.isEmpty
        }
        try #require(isQuiet, "the window never stopped rendering")
        let renders = RenderTally.recording {
          model.showsInspector = true
          screen.settle(0.3)
        }
        #expect(panel(screen) != nil)
        let chat = renders.filter { ["screen", "transcript", "rows", "composer"].contains($0.key) }
        #expect(chat.isEmpty, "the hidden chat rendered: \(renders)")
      }
    #endif
  }
#endif
