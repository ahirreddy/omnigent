#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("CLI status line", .serialized)
  @MainActor
  struct TranscriptCLIStatusLineTests {
    let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    static let models = [
      ModelOption(
        id: "fast", displayName: "Fast", defaultReasoningEffort: "low",
        supportedReasoningEfforts: ["low", "high"], isDefault: true),
      ModelOption(id: "deep", displayName: "Deep", supportedReasoningEfforts: ["high"]),
      ModelOption(id: "secret", displayName: "Secret", hidden: true),
    ]

    func composer(
      _ state: ComposerViewState = ComposerViewState(),
      actions: ComposerActions = ComposerActions(send: {}),
      layoutStyle: ComposerLayoutStyle = .card, layout: LayoutWidth = .regular,
      width: CGFloat = 800
    ) throws -> OffscreenWindow<AnyView> {
      try cliComposerScreen(
        state, actions: actions, layoutStyle: layoutStyle, layout: layout, width: width)
    }

    /// The menu holding `title`, tried control by control: the status line's menus draw as text.
    func menu(
      holding title: String, on screen: OffscreenWindow<AnyView>
    ) throws -> NSMenu {
      for frame in screen.controlFrames {
        let opened = try? screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
        if let opened, Self.holds(title, opened) { return opened }
      }
      Issue.record("No menu holds \(title)")
      return NSMenu()
    }

    static func holds(_ title: String, _ menu: NSMenu) -> Bool {
      menu.items.contains { item in
        item.title == title || (item.submenu.map { holds(title, $0) } ?? false)
      }
    }

    // MARK: The status line

    @Test("The status line spells out the model, effort, folder, branch and approval mode")
    func statusLine() throws {
      var configuration = ComposerConfiguration(
        modelOptions: Self.models, selectedModelId: "fast", selectedEffort: "high")
      configuration.agentName = "Otto"
      var tray = ComposerTray(directory: "~/src/project", branch: "feature/login")
      tray.contextFraction = 0.42
      let screen = try composer(
        ComposerViewState(
          configuration: configuration,
          approvalModes: ApprovalModes(
            options: [ApprovalModeOption(id: "ask", label: "Ask first")], selectedID: "ask"),
          tray: tray))
      defer { screen.close() }
      for text in ["Fast high", "~/src/project", "feature/login", "Ask first", "42% context"] {
        #expect(try screen.shows(text), "\(text)")
      }
      #expect(try !screen.shows("esc to interrupt"))
      #expect(try !screen.shows("plan mode"))
    }

    @Test("A narrow window drops the folder but keeps the indicators")
    func compactStatusLine() throws {
      var tray = ComposerTray(directory: "~/src/project", branch: "main")
      tray.contextFraction = 0.9
      let screen = try composer(
        ComposerViewState(tray: tray), layoutStyle: .touch, layout: .compact, width: 360)
      defer { screen.close() }
      #expect(try !screen.shows("~/src/project"))
      #expect(try screen.shows("main"))
      #expect(try screen.shows("90% context"))
    }

    @Test("The folder and branch fall back to the session's context")
    func contextFallback() throws {
      let screen = try composer(
        ComposerViewState(
          context: ExecutionContext(directory: "/work/repo", branch: "trunk")))
      defer { screen.close() }
      #expect(try screen.shows("/work/repo"))
      #expect(try screen.shows("trunk"))
    }

    @Test("While running, the card says Esc interrupts; touch has no Esc to mention")
    func escHint() throws {
      let card = try composer(ComposerViewState(isRunning: true))
      defer { card.close() }
      #expect(try card.shows("esc to interrupt"))
      let touch = try composer(ComposerViewState(isRunning: true), layoutStyle: .touch)
      defer { touch.close() }
      #expect(try !touch.shows("esc to interrupt"))
    }

    @Test("Plan mode shows for a session, not for a session being started")
    func planMode() throws {
      var extras = ComposerExtraActions()
      extras.isPlanOn = true
      let actions = ComposerActions(send: {}, extras: extras)
      let session = try composer(ComposerViewState(), actions: actions)
      defer { session.close() }
      #expect(try session.shows("plan mode"))
      let start = try composer(ComposerViewState(purpose: .start), actions: actions)
      defer { start.close() }
      #expect(try !start.shows("plan mode"))
    }

    @Test("The pull request chip opens the pull requests")
    func pullRequest() throws {
      var extras = ComposerExtraActions()
      let log = self.log
      extras.indicators.openPullRequests = { log.add("pull requests") }
      var tray = ComposerTray()
      tray.pullRequest = "#42"
      let screen = try composer(
        ComposerViewState(tray: tray), actions: ComposerActions(send: {}, extras: extras))
      defer { screen.close() }
      #expect(try screen.shows("#42"))
      for index in screen.controlFrames.indices {
        try screen.clickControl(at: index)
      }
      #expect(log.entries.contains("pull requests"))
    }

    @Test("A folder's shortest form keeps its name")
    func directoryMinimum() {
      #expect(CLIDirectoryText.minimumText("/Users/me/src/omnigent") == "\u{2026}/omnigent")
      #expect(CLIDirectoryText.minimumText("C:\\work\\repo") == "\u{2026}/repo")
      #expect(CLIDirectoryText.minimumText("name") == "name")
      #expect(CLIDirectoryText.minimumText("/") == "/")
      let long = "/work/" + String(repeating: "a", count: 40)
      #expect(
        CLIDirectoryText.minimumText(long) == "\u{2026}/\u{2026}"
          + String(repeating: "a", count: 23))
    }

  }

  // The model and approval menus, and the warnings.
  extension TranscriptCLIStatusLineTests {

    @Test("The model menu switches the model and effort, and offers the default back")
    func modelMenu() throws {
      var picked: [String?] = []
      var efforts: [String?] = []
      let screen = try composer(
        ComposerViewState(
          configuration: ComposerConfiguration(modelOptions: Self.models, selectedModelId: "fast")),
        actions: ComposerActions(
          send: {}, selectModel: { picked.append($0) }, selectEffort: { efforts.append($0) }))
      defer { screen.close() }
      #expect(try screen.shows("Fast low"))
      let opened = try menu(holding: "Deep", on: screen)
      #expect(!Self.holds("Secret", opened))
      try screen.choose("Deep", in: opened)
      #expect(picked == ["deep"])
      let again = try menu(holding: "Deep", on: screen)
      try screen.choose("Default (Fast)", in: again)
      #expect(picked == ["deep", nil])
      let effortMenu = try menu(holding: "Deep", on: screen)
      try screen.choose("High", in: effortMenu)
      #expect(efforts == ["high"])
      let backToDefault = try menu(holding: "Deep", on: screen)
      try screen.choose("Default (Low)", in: backToDefault)
      #expect(efforts == ["high", nil])
    }

    @Test("The model menu says why the last change failed; it can't be opened mid-change")
    func modelMenuStates() throws {
      let failing = try composer(
        ComposerViewState(
          configuration: ComposerConfiguration(
            modelOptions: Self.models, selectedModelId: "fast",
            errorMessage: "The agent refused")),
        actions: ComposerActions(send: {}, selectModel: { _ in }))
      defer { failing.close() }
      let opened = try menu(holding: "The agent refused", on: failing)
      #expect(Self.holds("Deep", opened))

      let applying = try composer(
        ComposerViewState(
          configuration: ComposerConfiguration(
            modelOptions: Self.models, selectedModelId: "fast", isApplying: true)),
        actions: ComposerActions(send: {}, selectModel: { _ in }))
      defer { applying.close() }
      #expect(applying.controlFrames.isEmpty)
    }

    @Test("Smart Routing is named in the status line and can be turned off from the menu")
    func smartRouting() throws {
      var configuration = ComposerConfiguration(modelOptions: Self.models, selectedModelId: "fast")
      configuration.smartRouting = .enabled
      var extras = ComposerExtraActions()
      var turnedOn: [Bool] = []
      extras.setSmartRouting = { turnedOn.append($0) }
      let screen = try composer(
        ComposerViewState(configuration: configuration),
        actions: ComposerActions(send: {}, selectModel: { _ in }, extras: extras))
      defer { screen.close() }
      #expect(try screen.shows(ComposerConfiguration.smartRoutingTitle))
      let opened = try menu(holding: ComposerConfiguration.smartRoutingTitle, on: screen)
      try screen.choose(ComposerConfiguration.smartRoutingTitle, in: opened)
      #expect(turnedOn == [false])
    }

    @Test("The approval menu lists the modes it can switch to and picks one")
    func approvalMenu() throws {
      var selected: [String] = []
      var extras = ComposerExtraActions()
      extras.selectApprovalMode = { selected.append($0.id) }
      let modes = ApprovalModes(
        options: [
          ApprovalModeOption(id: "ask", label: "Ask first"),
          ApprovalModeOption(id: "full", label: "Full access", risk: .fullAccess),
          ApprovalModeOption(id: "locked", label: "Managed", isSwitchable: false),
        ], selectedID: "ask")
      let screen = try composer(
        ComposerViewState(approvalModes: modes), actions: ComposerActions(send: {}, extras: extras))
      defer { screen.close() }
      let opened = try menu(holding: "Full access", on: screen)
      #expect(!Self.holds("Managed", opened))
      try screen.choose("Full access", in: opened)
      #expect(selected == ["full"])
    }

    @Test("A mode the host can't switch is just text, and nothing shows until one is reported")
    func approvalLabelOnly() throws {
      let fixed = try composer(
        ComposerViewState(
          approvalModes: ApprovalModes(
            options: [ApprovalModeOption(id: "full", label: "Full access", risk: .fullAccess)],
            selectedID: "full")))
      defer { fixed.close() }
      #expect(try fixed.shows("Full access"))
      #expect(fixed.controlFrames.isEmpty)
      let unreported = try composer(
        ComposerViewState(
          approvalModes: ApprovalModes(
            options: [ApprovalModeOption(id: "full", label: "Full access")], selectedID: nil)))
      defer { unreported.close() }
      #expect(try !unreported.shows("Full access"))
    }

    // MARK: Warnings

    @Test("Every problem counts as a warning, and the count opens a list of them")
    func warnings() throws {
      let screen = try composer(
        ComposerViewState(
          availability: .unavailable(reason: "Offline"),
          delivery: .failed(message: "Send failed"),
          attachments: [
            DraftAttachment(
              id: "a", title: "notes.txt", kind: .file, state: .failed(message: "Too big")),
            DraftAttachment(id: "b", title: "ok.txt", kind: .file),
          ],
          configuration: ComposerConfiguration(errorMessage: "Bad model"),
          context: ExecutionContext(unavailableReason: "Host is gone")))
      defer { screen.close() }
      #expect(try screen.shows("\u{26A0} 5 warnings"))
      let before = NSApp.windows.count
      let frame = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: frame.midX, y: frame.midY))
      screen.settle()
      #expect(NSApp.windows.count == before + 1)
      try screen.click(CGPoint(x: frame.midX, y: frame.midY))
      screen.settle()
    }

    @Test("One warning reads in the singular; none shows nothing")
    func oneWarning() throws {
      let one = try composer(ComposerViewState(availability: .unavailable(reason: "Offline")))
      defer { one.close() }
      #expect(try one.shows("\u{26A0} 1 warning"))
      let none = try composer()
      defer { none.close() }
      #expect(try !none.shows("warning"))
    }
  }
#endif
