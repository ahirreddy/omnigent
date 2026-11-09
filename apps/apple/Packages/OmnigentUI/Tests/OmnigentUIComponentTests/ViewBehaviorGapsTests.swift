#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import notify
  import Testing

  @testable import OmnigentUIComponents

  /// A window that says it's visible, so a view inside runs what only runs on screen. It's never
  /// ordered in.
  private final class ReportsVisibleWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { .visible }
  }

  /// Timers, hover and popovers across the design system, new session page and sheets.
  @Suite("View behavior edges", .serialized)
  @MainActor
  struct ViewBehaviorGapsTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
    }

    private func bitmapData<Content: View>(_ screen: OffscreenWindow<Content>) throws -> Data {
      let bitmap = try #require(screen.host.bitmapImageRepForCachingDisplay(in: screen.host.bounds))
      screen.host.cacheDisplay(in: screen.host.bounds, to: bitmap)
      return try #require(bitmap.tiffRepresentation)
    }

    @Test("A custom theme JSON can't hold isn't written, and the store keeps the last good one")
    func unencodableTheme() throws {
      var theme = CustomTheme.default
      #expect(throws: Never.self) { try ThemePreferences.encodeCustom(theme).get() }
      theme.contrast = .nan
      let key = ThemePreferences.customKey
      #expect(ThemePreferences.encodeCustom(theme) == .failure(.malformed(key: key)))
      #expect(ThemePreferences.storedJSON(Data([0xFF, 0xFE])) == .failure(.malformed(key: key)))

      let store = try #require(UserDefaults(suiteName: "theme-gaps-\(UUID())"))
      let preferences = ThemePreferences(defaults: store)
      preferences.custom = .default
      let saved = store.string(forKey: key)
      preferences.custom = theme
      #expect(preferences.readErrors == [.malformed(key: key)])
      #expect(store.string(forKey: key) == saved)
    }

    @Test("A stored custom theme decodes from any text, and bad text is reported")
    func decodesStoredTheme() throws {
      #expect(ThemePreferences.decodeCustom(nil) == .success(.default))
      let json = try ThemePreferences.encodeCustom(.default).get()
      #expect(ThemePreferences.decodeCustom(json) == .success(.default))
      let key = ThemePreferences.customKey
      #expect(ThemePreferences.decodeCustom("not json \u{1F680}") == .failure(.malformed(key: key)))
    }

    @Test("Copied goes back to the copy label after a moment")
    func copyConfirmationEnds() async throws {
      let screen = OffscreenWindow(
        CopyButton(
          text: "abc", label: "Copy code", showsLabel: true,
          confirmationDuration: .milliseconds(30)), width: 300, height: 100)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "abc")
      #expect(try screen.shows("Copied"))
      try await screen.letTasksRun(passes: 8)
      #expect(try !screen.shows("Copied"))
      #expect(try screen.shows("Copy code"))
    }

    @Test("A banner hides by itself, clearing its binding")
    func bannerExpires() async throws {
      let banner = EditedValue<TransientBanner?>(TransientBanner(message: "Saved"))
      let screen = OffscreenWindow(
        Color.clear.modifier(
          TransientBannerPresenter(
            banner: banner.binding, action: nil, duration: .milliseconds(20))),
        width: 300, height: 200)
      defer { screen.close() }
      #expect(try screen.shows("Saved"))
      try await screen.letTasksRun(passes: 8)
      #expect(banner.value == nil)
      #expect(try !screen.shows("Saved"))
    }

    @Test("An indicator on screen starts its loop, and stops when it's no longer wanted")
    func loopStartsOnScreen() throws {
      let window = ReportsVisibleWindow(
        contentRect: CGRect(x: -20_000, y: -20_000, width: 40, height: 20),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = LoopingLayerHost()
      host.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
      window.contentView = host
      defer { window.contentView = nil }
      let colors = LoopingColors(.secondary, in: EnvironmentValues())
      let fade = LoopingMotion.fade(low: 0.25, duration: 0.5, stagger: 0)
      host.configure(shape: .dot(diameter: 8), motion: fade, colors: colors, isAnimating: true)
      let part = try #require(host.layer?.sublayers?.first?.sublayers?.first)
      #expect(host.isAnimating)
      #expect(part.animationKeys()?.isEmpty == false)
      host.configure(shape: .dot(diameter: 8), motion: fade, colors: colors, isAnimating: false)
      #expect(part.animationKeys() == nil)
    }

    @Test("The perf hooks open and close the palette")
    func paletteHooks() async throws {
      let screen = OffscreenWindow(
        Color.clear.commandPalette(
          state: PaletteViewState(
            scope: "Studio", sessions: [], servers: [], hasNextRequest: false),
          actions: PaletteActions { _ in }), width: 640, height: 560)
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(screen.window.attachedSheet == nil)
      _ = unsafe notify_post("ai.omnigent.perf.palette")
      for _ in 0..<100 where screen.window.attachedSheet == nil {
        try await screen.letTasksRun(passes: 1)
      }
      #expect(screen.window.attachedSheet != nil)
      _ = unsafe notify_post("ai.omnigent.perf.palette.close")
      for _ in 0..<100 where screen.window.attachedSheet != nil {
        try await screen.letTasksRun(passes: 1)
      }
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("The split item finder takes no clicks of its own")
    func detailFinderPassesClicks() throws {
      var clicks = 0
      let screen = OffscreenWindow(
        Button("Under") { clicks += 1 }.detailBesideSidebar(), width: 200, height: 100)
      defer { screen.close() }
      let finder = try #require(
        screen.allViews.first { String(describing: type(of: $0)).contains("ItemView") })
      #expect(finder.hitTest(CGPoint(x: 1, y: 1)) == nil)
      try screen.clickControl(at: 0)
      #expect(clicks == 1)
    }

    @Test("Copied! goes back to Copy link after a moment")
    func shareCopiedEnds() async throws {
      let link = try #require(URL(string: "https://example.test/s"))
      var sheet = ShareSheet(state: ShareViewState(link: link), actions: ShareActions()) {}
      sheet.copiedDuration = .milliseconds(30)
      let shown = sheet
      let screen = OffscreenWindow(
        AnyView(Color.clear.sheet(isPresented: .constant(true)) { shown }), width: 700, height: 700)
      defer { screen.close() }
      screen.settle(0.2)
      try screen.clickControl(at: screen.controlFrames.count - 3)
      #expect(try screen.shows("Copied!"))
      try await screen.letTasksRun(passes: 8)
      #expect(try !screen.shows("Copied!"))
      #expect(try screen.shows("Copy link"))
    }

    @Test("Otto's eyes follow the pointer over the page's heading, and rest when it leaves")
    func heroGaze() throws {
      var state = ComposerViewState()
      state.purpose = .start
      let screen = OffscreenWindow(
        NewSessionPage(
          draft: .constant(""), composer: state, actions: ComposerActions(send: {}), heading: "Hi",
          importSessions: nil, options: nil, optionActions: NewSessionOptionActions()),
        width: 800, height: 600)
      defer { screen.close() }
      let resting = try bitmapData(screen)
      var moved = false
      for row in stride(from: 40, to: 560, by: 40) where !moved {
        try screen.hover(CGPoint(x: 400, y: row))
        screen.settle(0.2)
        moved = try bitmapData(screen) != resting
      }
      #expect(moved, "the eyes moved")
      try screen.endHover()
      screen.settle(0.2)
      #expect(try bitmapData(screen) == resting)
    }

    @Test("Use Branch in the worktree form picks it and closes the form")
    func worktreeForm() throws {
      var chosen: [NewSessionWorktreeChoice] = []
      var options = NewSessionOptions(folder: "/src/app", offersWorktrees: true)
      options.worktree = .new(branch: "feature/x", base: "main")
      let actions = NewSessionOptionActions(selectWorktree: { chosen.append($0) })
      let screen = OffscreenWindow(
        NewSessionOptionsBar(options: options, actions: actions)
          .frame(width: 800, height: 600, alignment: .top))
      defer { screen.close() }
      try screen.choose("New Worktree\u{2026}", in: try screen.menu(at: 1))
      screen.settle(0.2)
      try screen.clickPopoverButton(fromRight: 0)
      #expect(chosen == [.new(branch: "feature/x", base: "main")])
      #expect(screen.popoverWindow == nil)
    }

    @Test("Choose opens the system's character palette for the project's icon")
    func chooseProjectIcon() throws {
      // The real palette is a window on the user's screen, so the test keeps it from opening.
      let selector = #selector(NSApplication.orderFrontCharacterPalette(_:))
      guard let method = unsafe class_getInstanceMethod(NSApplication.self, selector) else {
        Issue.record("NSApplication has no character palette")
        return
      }
      nonisolated(unsafe) var opened = 0
      let record: @convention(block) (NSApplication, Any?) -> Void = { _, _ in unsafe opened += 1 }
      let original = unsafe method_setImplementation(method, imp_implementationWithBlock(record))
      defer { unsafe method_setImplementation(method, original) }

      var state = SidebarFixture.state
      state.projects = [SessionProject(id: "p1", name: "Work", sessionIds: ["beta"])]
      state.projectSort = .alphabetical
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      try screen.choose("Rename project\u{2026}", in: try #require(try screen.menu(ofRow: 8)))
      // The sheet's title bar control comes first, then Choose.
      try screen.clickButton(at: 1)
      #expect(unsafe opened == 1)
    }

    @Test("The toolbar offers the project tag and toggles the right panel")
    func toolbarItems() throws {
      let inspector = EditedValue(false)
      let moved = EditedValue<[String]>([])
      var state = ConversationViewState(header: TranscriptFixture.header)
      state.summary = SessionSummary(id: "session-1", title: "A session")
      var extras = ConversationExtras()
      extras.sessionActions.moveToProject = { session, _ in moved.value.append(session.id) }
      let items = ConversationToolbarItems(
        state: state, extras: extras, offersTerminal: false, tabsInTitlebar: false,
        isRegular: true, showsProjectTag: true, mode: .constant(.chat),
        showsInspector: inspector.binding, showsInfo: .constant(false), showShare: {},
        titleMenu: AnyView(EmptyView()))
      let screen = toolbarWindow(items)
      defer { screen.close() }
      #expect(screen.window.toolbar?.items.map(\.label) == ["Add to project", "Right panel"])
      try screen.press(keyCode: 30, characters: "]", modifiers: [.command, .option])
      #expect(inspector.value)
      try screen.press(keyCode: 30, characters: "]", modifiers: [.command, .option])
      #expect(!inspector.value)
    }

    @Test("Reply to a selection in a conversation quotes it for the composer")
    func replyFromConversation() async throws {
      let log = HostLog()
      var actions = ConversationActions()
      actions.replyWithSelection = { log.add($0) }
      let draft = EditedValue("")
      let inspector = EditedValue(false)
      let state = ConversationViewState(
        header: TranscriptFixture.header,
        rows: [TranscriptFixture.answer("a", "A long answer to select from.")])
      let screen = transcriptScreen(
        ConversationScreen(
          state: state, composer: ComposerViewState(), draft: ComposerDraft(draft.binding),
          showsInspector: inspector.binding, mode: .constant(.chat), fork: .constant(nil),
          actions: actions, composerActions: ComposerActions(send: {}),
          extras: ConversationExtras()
        ) { EmptyView() }, actions: actions, width: 800, height: 600)
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 200)
      try screen.click(CGPoint(x: 90, y: 60), clickCount: 2)
      try await announceSelection(screen)
      try screen.clickControl(at: 0)
      try await letTasksRun(screen, milliseconds: 100)
      #expect(log.entries == ["answer"])
      #expect(screen.window.firstResponder === screen.textView, "the composer takes the typing")
    }
  }

  extension ViewBehaviorGapsTests {
    /// A window whose toolbar holds a conversation's items, as the app's windows show them.
    private func toolbarWindow(_ items: ConversationToolbarItems) -> OffscreenWindow<some View> {
      let screen = OffscreenWindow(
        NavigationStack { Color.clear.toolbar { ConversationToolbar(items: items) } },
        width: 900, height: 400)
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      screen.settle(0.5)
      return screen
    }

    /// The labels of the toolbar items a chat with a ready terminal shows, spaces left out.
    private func toolbarLabels(offersTerminal: Bool, tabsInTitlebar: Bool) -> [String] {
      let items = ConversationToolbarItems(
        state: ConversationViewState(header: TranscriptFixture.header, terminal: .ready),
        extras: ConversationExtras(), offersTerminal: offersTerminal,
        tabsInTitlebar: tabsInTitlebar, isRegular: true, showsProjectTag: false,
        mode: .constant(.chat), showsInspector: .constant(false), showsInfo: .constant(false),
        showShare: {}, titleMenu: AnyView(EmptyView()))
      let screen = toolbarWindow(items)
      defer { screen.close() }
      return (screen.window.toolbar?.items.map(\.label) ?? []).filter { !$0.isEmpty }
    }

    @Test("With the tabs in the titlebar, Chat / Terminal leads the trailing toolbar items")
    func viewSwitchBesideTheTabs() {
      #expect(
        toolbarLabels(offersTerminal: true, tabsInTitlebar: true)
          == ["View", "Session", "Right panel"])
      #expect(
        toolbarLabels(offersTerminal: false, tabsInTitlebar: true)
          == ["Session", "Right panel"], "a chat without a terminal has no switch")
      #expect(
        toolbarLabels(offersTerminal: true, tabsInTitlebar: false) == ["View", "Right panel"],
        "without tabs the switch holds the middle")
    }
  }
#endif
