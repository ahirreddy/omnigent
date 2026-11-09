#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Records what the start options ask of the host.
  @MainActor
  final class NewSessionOptionLog {
    var events: [String] = []
    var worktrees: [NewSessionWorktreeChoice] = []
    var repos: [[SandboxRepoChoice]] = []
    var profiles: [String] = []

    private func recorder(_ name: String) -> @MainActor () -> Void {
      { self.events.append(name) }
    }

    /// Every action wired to this log; a test sets the ones it needs absent back to `nil`.
    var actions: NewSessionOptionActions {
      var actions = NewSessionOptionActions(
        selectFolder: { path in self.events.append("folder:\(path)") },
        browse: { path in
          self.events.append("browse:\(path ?? "home")")
          return .success(
            FolderListing(path: path ?? "/home", parent: nil, folders: []))
        },
        selectWorktree: { choice in self.worktrees.append(choice) },
        setUpHarness: recorder("setUp"))
      actions.connectHost = recorder("connect")
      actions.selectProject = { name in self.events.append("project:\(name ?? "none")") }
      return actions
    }
  }

  /// The new-session page and the chips under its composer.
  @Suite("New session page", .serialized)
  @MainActor
  struct NewSessionPageTests {
    fileprivate let log = NewSessionOptionLog()
    private let composerLog = ComposerActionLog()

    fileprivate func bar(
      _ options: NewSessionOptions, actions: NewSessionOptionActions? = nil
    ) -> OffscreenWindow<some View> {
      let root = NewSessionOptionsBar(options: options, actions: actions ?? log.actions)
        .frame(width: 800, height: 600, alignment: .top)
      let screen = OffscreenWindow(root)
      screen.settle()
      return screen
    }

    private func page(
      heading: String = NewSessionPage.defaultHeading, draft: String = "",
      importSessions: (@MainActor () -> Void)? = nil, options: NewSessionOptions? = nil,
      layout: ComposerLayoutStyle = .platformDefault, width: LayoutWidth = .regular
    ) -> OffscreenWindow<some View> {
      var state = ComposerViewState()
      state.purpose = .start
      let root = NewSessionPage(
        draft: .constant(draft), composer: state, actions: composerLog.actions, heading: heading,
        importSessions: importSessions, options: options, optionActions: log.actions
      )
      .environment(\.composerLayoutStyle, layout)
      .environment(\.layoutWidth, width)
      .frame(width: 800, height: 600)
      let screen = OffscreenWindow(root)
      screen.settle()
      return screen
    }

    // MARK: The page

    @Test("The page names itself and holds the composer, with the options under it")
    func pageContents() throws {
      let screen = page(options: NewSessionOptions(folder: "/src/app"))
      defer { screen.close() }
      #expect(try screen.shows(NewSessionPage.defaultHeading))
      #expect(screen.textView != nil)
      #expect(try screen.shows("app"))
    }

    @Test("A server's heading replaces the default")
    func pageHeading() throws {
      let screen = page(heading: "Ship something")
      defer { screen.close() }
      #expect(try screen.shows("Ship something"))
      #expect(try !screen.shows(NewSessionPage.defaultHeading))
    }

    @Test("With a way to import, the button is there and imports")
    func pageImport() throws {
      let imported = ImportCounter()
      let screen = page(importSessions: { imported.count += 1 })
      defer { screen.close() }
      #expect(try screen.shows("Import your recent sessions"))
      try screen.tapButton(fromEnd: 0)
      #expect(imported.count == 1)

      let without = page()
      defer { without.close() }
      #expect(try !without.shows("Import your recent sessions"))
    }

    @Test("A phone pins the composer under the heading, with import above it")
    func pagePhone() throws {
      let imported = ImportCounter()
      let screen = page(
        importSessions: { imported.count += 1 }, layout: .touch, width: .compact)
      defer { screen.close() }
      #expect(try screen.shows(NewSessionPage.defaultHeading))
      #expect(try screen.shows("Import your recent sessions"))
      #expect(screen.textView != nil)
      try screen.tapButton(0)
      #expect(imported.count == 1)
    }

    @Test("Otto's eyes follow the pointer, and rest when it leaves")
    func pageHover() throws {
      let screen = page()
      defer { screen.close() }
      let before = screen.window.contentView.flatMap {
        $0.bitmapImageRepForCachingDisplay(in: $0.bounds)
      }
      #expect(before != nil)
      try screen.hover(CGPoint(x: 100, y: 100))
      screen.settle(0.05)
      try screen.hover(CGPoint(x: 700, y: 100))
      screen.settle(0.05)
      try screen.endHover()
      screen.settle(0.05)
      #expect(try screen.shows(NewSessionPage.defaultHeading))
    }

    // MARK: Notices

    @Test("With no host the notice says so and connects one")
    func hostNotice() throws {
      var options = NewSessionOptions()
      options.needsHost = true
      let screen = bar(options)
      defer { screen.close() }
      #expect(try screen.shows("No host is connected, so agents can't run yet."))
      try screen.tapButton(0)
      #expect(log.events == ["connect"])

      var noAction = log.actions
      noAction.connectHost = nil
      let bare = bar(options, actions: noAction)
      defer { bare.close() }
      #expect(try bare.shows("No host is connected, so agents can't run yet."))
      #expect(try !bare.shows("Connect a Host\u{2026}"))
    }

    @Test("An agent that isn't ready says so and sets up, named when it can be")
    func harnessNotice() throws {
      let named = bar(NewSessionOptions(harnessNotice: "Codex isn't ready.", setUpName: "Codex"))
      defer { named.close() }
      #expect(try named.shows("Codex isn't ready."))
      #expect(try named.shows("Set Up Codex\u{2026}"))
      try named.tapButton(0)
      #expect(log.events == ["setUp"])

      let unnamed = bar(NewSessionOptions(harnessNotice: "Not ready."))
      defer { unnamed.close() }
      #expect(try unnamed.shows("Set Up Agent\u{2026}"))

      var noAction = log.actions
      noAction.setUpHarness = nil
      let bare = bar(NewSessionOptions(harnessNotice: "Not ready."), actions: noAction)
      defer { bare.close() }
      #expect(try !bare.shows("Set Up"))
    }

  }

  extension NewSessionPageTests {
    // MARK: Folder

    @Test("The folder chip offers browsing first, then recents")
    func folderMenu() throws {
      let screen = bar(NewSessionOptions(folder: "/src/app", recentFolders: ["/a", "/b"]))
      defer { screen.close() }
      #expect(try screen.shows("app"))
      let menu = try screen.menu(at: 0)
      #expect(menuTitles(menu) == ["Browse Folders\u{2026}", "Folders", "/a", "/b"])
      try screen.choose("/b", in: menu)
      #expect(log.events == ["folder:/b"])
    }

    @Test("With no folder the chip asks for one")
    func folderNone() throws {
      var actions = log.actions
      actions.browse = nil
      let screen = bar(NewSessionOptions(), actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Choose folder"))
      #expect(menuTitles(try screen.menu(at: 0)).isEmpty)
    }

    @Test("Browsing opens the host's folders from the chosen one, and choosing closes it")
    func folderBrowse() async throws {
      let screen = bar(NewSessionOptions(folder: "/src/app"))
      defer { screen.close() }
      try screen.choose("Browse Folders\u{2026}", in: try screen.menu(at: 0))
      screen.settle(0.5)
      await screen.drainTasks()
      #expect(screen.window.attachedSheet != nil)
      #expect(log.events == ["browse:/src/app"])
      #expect(try screen.shows("Choose a Folder"))
      try screen.tapButton(fromEnd: 0)
      screen.settle(0.5)
      #expect(log.events.last == "folder:/src/app")
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("Canceling the browser chooses nothing")
    func folderBrowseCancel() async throws {
      let screen = bar(NewSessionOptions(folder: "/src/app"))
      defer { screen.close() }
      try screen.choose("Browse Folders\u{2026}", in: try screen.menu(at: 0))
      screen.settle(0.5)
      await screen.drainTasks()
      try screen.tapButton(fromEnd: 1)
      screen.settle(0.5)
      #expect(log.events == ["browse:/src/app"])
      #expect(screen.window.attachedSheet == nil)
    }

    // MARK: Worktree

    @Test("The worktree chip names the choice, and offers them all")
    func worktreeMenu() throws {
      let existing = NewSessionWorktreeOption(path: "/w/one", branch: "one")
      let detached = NewSessionWorktreeOption(path: "/w/detached", branch: nil)
      let screen = bar(
        NewSessionOptions(
          folder: "/src/app", offersWorktrees: true, worktrees: [existing, detached]))
      defer { screen.close() }
      #expect(try screen.shows("No worktree"))
      let menu = try screen.menu(at: 1)
      #expect(
        menuTitles(menu) == [
          "No worktree", "New Worktree\u{2026}", "Existing worktrees", "one", "detached",
        ])
      try screen.choose("No worktree", in: menu)
      try screen.choose("detached", in: menu)
      #expect(log.worktrees == [.none, .existing(detached)])
    }

    @Test("Each worktree choice titles the chip")
    func worktreeTitles() {
      let branch = NewSessionWorktreeOption(path: "/w/one", branch: "one")
      let detached = NewSessionWorktreeOption(path: "/w/two", branch: nil)
      #expect(NewSessionOptions().worktreeTitle == "No worktree")
      #expect(
        NewSessionOptions(worktree: .new(branch: "f", base: "")).worktreeTitle == "New branch: f")
      #expect(NewSessionOptions(worktree: .existing(branch)).worktreeTitle == "Worktree: one")
      #expect(NewSessionOptions(worktree: .existing(detached)).worktreeTitle == "Worktree: /w/two")
    }

    @Test("With no git repository, or no handler, there's no worktree chip")
    func worktreeAbsent() throws {
      let noRepo = bar(NewSessionOptions(folder: "/src/app"))
      defer { noRepo.close() }
      #expect(noRepo.menus.count == 1)

      var actions = log.actions
      actions.selectWorktree = nil
      let noHandler = bar(
        NewSessionOptions(folder: "/src/app", offersWorktrees: true), actions: actions)
      defer { noHandler.close() }
      #expect(noHandler.menus.count == 1)
    }

    // MARK: Project and plan

    @Test("The project chip picks a project or none")
    func project() throws {
      var options = NewSessionOptions(folder: "/src/app")
      options.project = "Alpha"
      options.projects = ["Alpha", "Beta"]
      let screen = bar(options)
      defer { screen.close() }
      #expect(try screen.shows("Alpha"))
      let menu = try screen.menu(at: 1)
      #expect(menuTitles(menu) == ["No Project", "Projects", "Alpha", "Beta"])
      try screen.choose("Beta", in: menu)
      try screen.choose("No Project", in: menu)
      #expect(log.events == ["project:Beta", "project:none"])
    }

    @Test("With no projects at all there's no chip; a filed session keeps it")
    func projectAbsent() throws {
      let none = bar(NewSessionOptions())
      defer { none.close() }
      #expect(try !none.shows("No project"))

      var filed = NewSessionOptions()
      filed.project = "Alpha"
      let kept = bar(filed)
      defer { kept.close() }
      #expect(menuTitles(try kept.menu(at: 1)) == ["No Project"])
    }

    @Test("Armed plan mode shows")
    func planMode() throws {
      let screen = bar(NewSessionOptions(isPlanMode: true))
      defer { screen.close() }
      #expect(try screen.shows("Plan mode"))
    }

    // MARK: Connect a host

    @Test("The host command is quoted when it has to be")
    func shellQuoting() {
      #expect(ConnectHostSheet.shellQuoted("https://a.test:8080/x") == "https://a.test:8080/x")
      #expect(ConnectHostSheet.shellQuoted("a b") == "'a b'")
      #expect(ConnectHostSheet.shellQuoted("it's") == "'it'\\''s'")
    }

    @Test("Connect a Host shows the command, which copies; Done closes")
    func connectHost() throws {
      SystemSideEffects.reset()
      let closes = ImportCounter()
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: ConnectHostSheet(serverURL: "https://a.test") { closes.count += 1 }))
      defer { screen.close() }
      screen.settle(0.5)
      #expect(try screen.shows("omni host --server https://a.test"))
      #expect(try !screen.shows("Use This Mac"))
      try screen.tapButton(1)
      #expect(
        SystemSideEffects.pasteboard.string(forType: .string) == "omni host --server https://a.test"
      )
      try screen.tapButton(fromEnd: 0)
      #expect(closes.count == 1)
    }

    @Test("Use This Mac reports how it went; nothing to report leaves no line")
    func useThisMac() async throws {
      let answers = AnswerQueue(["Connected", nil])
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: ConnectHostSheet(
            serverURL: "https://a.test", useThisMachine: { answers.next() }, close: {})))
      defer { screen.close() }
      screen.settle(0.5)
      #expect(try screen.shows("Runs the Omnigent host on this Mac for this server."))
      try screen.tapButton(fromEnd: 1)
      await screen.drainTasks()
      #expect(try screen.shows("Connected"))
      try screen.tapButton(fromEnd: 1)
      await screen.drainTasks()
      #expect(try !screen.shows("Connected"))
    }

  }

  @MainActor
  private final class ImportCounter {
    var count = 0
  }

  @MainActor
  private final class AnswerQueue {
    private var answers: [String?]

    init(_ answers: [String?]) { self.answers = answers }

    func next() -> String? { answers.removeFirst() }
  }
#endif
