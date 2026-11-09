#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Lets a test change the sheet's state after it opens, as a host list arriving does.
  @MainActor
  @Observable
  private final class ForkHost {
    var state: ForkViewState
    init(_ state: ForkViewState) { self.state = state }
  }

  private struct ForkHarness: View {
    let host: ForkHost
    let actions: ForkActions

    var body: some View {
      Color.clear.sheet(isPresented: .constant(true)) {
        ForkSheet(state: host.state, actions: actions)
      }
    }
  }

  private let forkAgents = [
    CreationAgent(id: "a", name: "Agent A", harness: "claude"),
    CreationAgent(id: "b", name: "Agent B", harness: "codex"),
  ]

  func forkState(
    _ kind: ForkViewState.Kind = .session, options: ForkOptions = ForkOptions(),
    recent: [String] = [], isForking: Bool = false, error: String? = nil,
    unavailable: String? = nil
  ) -> ForkViewState {
    var state = ForkViewState(
      id: "f", kind: kind, agents: forkAgents, agentID: "a", directory: "/repo",
      recentDirectories: recent, isForking: isForking, errorMessage: error,
      startUnavailableReason: unavailable)
    state.options = options
    return state
  }

  @MainActor
  func forkActions(_ log: SheetLog) -> ForkActions {
    var actions = ForkActions(
      forkWith: {
        log.choices = $0
        log.calls.append("fork start=\($0.start)")
      },
      selectionChanged: { log.calls.append("selection \($0) \($1 ?? "-")") },
      cancel: { log.calls.append("cancel") })
    actions.sandboxSelected = { log.calls.append("sandbox \($0 ?? "-")") }
    return actions
  }

  @MainActor
  func forkSheet(_ state: ForkViewState, _ actions: ForkActions) -> OffscreenWindow<AnyView> {
    OffscreenWindow(
      AnyView(ForkHarness(host: ForkHost(state), actions: actions)), width: 700, height: 800)
  }

  @Suite("Inspector: the fork sheet", .serialized)
  @MainActor
  struct InspectorForkSheetTests {
    @Test("Each kind has its title and verbs")
    func kinds() {
      #expect(forkState(.session).title == "Clone session")
      #expect(forkState(.session).verb == "Clone")
      #expect(forkState(.fromMessage(rowID: "r")).title == "Fork from this response")
      #expect(forkState(.fromMessage(rowID: "r")).verb == "Fork")
      #expect(forkState(.anotherDirectory).title == "Continue in another directory")
      #expect(forkState(.anotherDirectory).verb == "Continue")
    }

    @Test("Opening reports the selection; Cancel cancels")
    func cancel() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(), forkActions(log))
      defer { screen.close() }
      #expect(log.calls == ["selection a -"])
      #expect(try screen.shows("Clone session"))
      // Cancel, Clone, Clone & start.
      try screen.clickBar(fromLast: 2)
      #expect(log.calls.last == "cancel")
    }

    @Test("Clone copies without starting; Clone & start starts")
    func cloneAndStart() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(), forkActions(log))
      defer { screen.close() }
      #expect(try screen.shows("Clone"))
      #expect(try screen.shows("Clone & start"))
      try screen.clickBar(fromLast: 1)
      #expect(log.choices?.start == false)
      #expect(log.choices?.directory == "/repo")
      #expect(log.choices?.agentID == "a")
      try screen.clickBar()
      #expect(log.choices?.start == true)
    }

    @Test("From a message the verb is Fork")
    func fromMessage() throws {
      let screen = forkSheet(forkState(.fromMessage(rowID: "r")), forkActions(SheetLog()))
      defer { screen.close() }
      #expect(try screen.shows("Fork from this response"))
      #expect(try screen.shows("Fork & start"))
    }

    @Test("Another directory explains itself, and Continue starts")
    func anotherDirectory() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(.anotherDirectory, unavailable: "No host"), forkActions(log))
      defer { screen.close() }
      #expect(try screen.shows("Directory"))
      #expect(try !screen.shows("No host"))
      try screen.clickBar()
      #expect(log.choices?.start == true)
    }

    @Test("Changing the agent reports it")
    func agentChange() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(), forkActions(log))
      defer { screen.close() }
      try screen.pick("Agent B", in: try #require(screen.pickers.first))
      #expect(log.calls == ["selection a -", "selection b -"])
      try screen.clickBar()
      #expect(log.choices?.agentID == "b")
    }

    @Test("When it can't start, it says why and only Clone is left, with no directory")
    func unavailable() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(unavailable: "The host is offline."), forkActions(log))
      defer { screen.close() }
      #expect(
        try screen.shows("Clone copies the conversation without starting it. The host is offline."))
      #expect(try !screen.shows("Directory"))
      #expect(try !screen.shows("Clone & start"))
      try screen.clickBar()
      #expect(log.choices?.start == false)
    }

    @Test("A host's own reason counts once hosts are listed")
    func hostReason() throws {
      let options = ForkOptions(hosts: [
        ForkHostOption(id: "down", name: "Down box", unavailableReason: "It's asleep."),
        ForkHostOption(id: "up", name: "Up box"),
      ])
      let log = SheetLog()
      let screen = forkSheet(forkState(options: options), forkActions(log))
      defer { screen.close() }
      #expect(log.calls == ["selection a down"])
      #expect(try screen.shows("Clone copies the conversation without starting it. It's asleep."))
      try screen.pick("Up box", in: screen.pickers[1])
      #expect(log.calls.last == "selection a up")
      #expect(try screen.shows("Directory"))
      #expect(try screen.openMenu(screen.pickers[1]).item(named: "Down box (unavailable)") != nil)
    }

    @Test("A host list that arrives after opening starts on the first host")
    func lateHosts() throws {
      let log = SheetLog()
      let host = ForkHost(forkState())
      let screen = OffscreenWindow(
        AnyView(ForkHarness(host: host, actions: forkActions(log))), width: 700, height: 800)
      defer { screen.close() }
      host.state.options = ForkOptions(hosts: [ForkHostOption(id: "h", name: "Box")])
      screen.settle(0.05)
      #expect(log.calls.last == "selection a h")
    }

    @Test("An error shows; while forking the buttons are off and a spinner shows")
    func errorAndForking() throws {
      let failed = forkSheet(forkState(error: "It broke"), forkActions(SheetLog()))
      defer { failed.close() }
      #expect(try failed.shows("It broke"))
      let log = SheetLog()
      let busy = forkSheet(forkState(isForking: true), forkActions(log))
      defer { busy.close() }
      #expect(try busy.shows("Clone & start"))
      // Only Cancel still takes a click.
      try busy.clickBar()
      #expect(log.choices == nil)
      #expect(log.calls.last == "cancel")
      #expect(
        busy.allViews.contains { String(describing: Swift.type(of: $0)).contains("Progress") })
    }

    @Test("A recent directory fills the field")
    func recentDirectory() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(recent: ["/one", "/two"]), forkActions(log))
      defer { screen.close() }
      try screen.pick("/two", in: try #require(screen.pickers.last))
      try screen.clickBar()
      #expect(log.choices?.directory == "/two")
    }

    @Test("A typed directory is what forks")
    func typedDirectory() throws {
      let log = SheetLog()
      let screen = forkSheet(forkState(), forkActions(log))
      defer { screen.close() }
      let field = try #require(
        screen.allViews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "/repo" })
      try screen.click(field)
      try screen.type("/x")
      try screen.clickBar()
      #expect(log.choices?.directory == "/x/repo")
    }

    private func browsing(_ log: SheetLog) -> ForkActions {
      var withBrowse = forkActions(log)
      withBrowse.browse = { host, path in
        log.calls.append("browse \(host ?? "-") \(path ?? "-")")
        return .success(
          FolderListing(path: path, parent: "/", folders: [.init(path: "/repo/sub", name: "sub")]))
      }
      return withBrowse
    }

    /// The form as a window's root, so the browser it opens is the window's first sheet.
    private func rootForm(_ state: ForkViewState, _ actions: ForkActions) -> OffscreenWindow<
      AnyView
    > {
      OffscreenWindow(AnyView(ForkSheet(state: state, actions: actions)), width: 700, height: 800)
    }

    @Test("Browse opens the folder browser at the directory, and Choose fills the field")
    func browse() async throws {
      let log = SheetLog()
      let screen = rootForm(forkState(), browsing(log))
      defer { screen.close() }
      // Agent, Advanced, then the browse button.
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(screen.window.attachedSheet != nil)
      try await Task.sleep(for: .milliseconds(30))
      screen.settle(0.05)
      #expect(log.calls.contains("browse - /repo"))
      #expect(try screen.shows("Choose a Folder"))
      #expect(try screen.shows("sub"))
      // Cancel and Choose close the bar's end.
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("Cancelling the browser leaves the directory alone")
    func browseCancel() async throws {
      let log = SheetLog()
      let screen = rootForm(forkState(), browsing(log))
      defer { screen.close() }
      try screen.clickControl(at: screen.controlFrames.count - 1)
      try await Task.sleep(for: .milliseconds(30))
      screen.settle(0.05)
      // Cancel, then Choose.
      try screen.clickControl(at: screen.controlFrames.count - 2)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("With no directory set the browser starts at the host's default")
    func browseFromNothing() async throws {
      let log = SheetLog()
      var empty = forkState()
      empty.directory = ""
      let screen = rootForm(empty, browsing(log))
      defer { screen.close() }
      try screen.clickControl(at: screen.controlFrames.count - 1)
      try await Task.sleep(for: .milliseconds(30))
      screen.settle(0.05)
      #expect(log.calls.contains("browse - -"))
    }

    @Test("The sheet's identity follows the fork in progress, and clearing it clears the fork")
    func sheetID() {
      var fork: ForkViewState? = forkState()
      let binding = ForkSheetID.binding(
        Binding(get: { fork }, set: { fork = $0 }))
      #expect(binding.wrappedValue?.id == "f")
      binding.wrappedValue = ForkSheetID(id: "other")
      #expect(fork != nil)
      binding.wrappedValue = nil
      #expect(fork == nil)
    }
  }

  extension OffscreenWindow {
    /// Clicks a button in the sheet's bar, counted from the last.
    func clickBar(fromLast offset: Int = 0) throws {
      try clickControl(at: controlFrames.count - 1 - offset)
    }

    /// Whether any text on screen contains this, for long lines.
    func shows(containing text: String) throws -> Bool {
      try shownText().contains { $0.contains(text) }
    }
  }
#endif
