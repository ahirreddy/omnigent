#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Holds what a screen hands its toolbar, as the app's tab host receives it.
  @MainActor
  private final class ToolbarItemsBox {
    var items: ConversationToolbarItems?
  }

  private struct MenuScreenHost: View {
    let state: ConversationViewState
    let actions: ConversationActions
    let extras: ConversationExtras
    let box: ToolbarItemsBox
    @State private var mode = SessionViewMode.chat
    @State private var showsInspector = false
    @State private var draft = ""
    @State private var fork: ForkViewState?

    init(
      state: ConversationViewState, actions: ConversationActions, extras: ConversationExtras,
      box: ToolbarItemsBox, fork: ForkViewState? = nil
    ) {
      self.state = state
      self.actions = actions
      self.extras = extras
      self.box = box
      _fork = State(initialValue: fork)
    }

    var body: some View {
      ConversationScreen(
        state: state, composer: ComposerViewState(), draft: ComposerDraft($draft),
        showsInspector: $showsInspector, mode: $mode, fork: $fork, actions: actions,
        composerActions: ComposerActions(send: {}), extras: extras
      ) {
        Text("terminal")
      }
      .hostsConversationToolbar()
      .backgroundPreferenceValue(ConversationToolbarKey.self) { items in
        box.items = items
        return Color.clear
      }
    }
  }

  @Suite("Conversation title menu", .serialized)
  @MainActor
  struct TranscriptScreenMenuTests {
    private let log = HostLog()
    private let box = ToolbarItemsBox()

    init() {
      SystemSideEffects.reset()
    }

    private var summary: SessionSummary { SessionSummary(id: "session-1", title: "A session") }

    private func conversation(summary: SessionSummary? = nil) -> ConversationViewState {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")])
      state.summary = summary
      return state
    }

    private func screen(
      _ state: ConversationViewState, actions: ConversationActions = ConversationActions(),
      extras: ConversationExtras = ConversationExtras(), fork: ForkViewState? = nil,
      layout: LayoutWidth = .regular
    ) async throws -> OffscreenWindow<AnyView> {
      let window = transcriptScreen(
        MenuScreenHost(state: state, actions: actions, extras: extras, box: box, fork: fork),
        width: 900, height: 600, layout: layout)
      try await letTasksRun(window, milliseconds: 150)
      return window
    }

    /// The title menu's items as plain buttons, drawn in a window of their own.
    private func titleMenu() throws -> OffscreenWindow<AnyView> {
      let items = try #require(box.items)
      return transcriptScreen(VStack { items.titleMenu }, height: 600)
    }

    @Test("Without a summary the menu copies the session's id")
    func copiesSessionID() async throws {
      let window = try await screen(conversation())
      defer { window.close() }
      let menu = try titleMenu()
      defer { menu.close() }
      #expect(try menu.shows("Copy Session ID"))
      try menu.clickControl(at: 0)
      #expect(copiedText() == TranscriptFixture.header.id)
    }

    @Test("Export runs the host's export")
    func export() async throws {
      let log = self.log
      let window = try await screen(
        conversation(), extras: ConversationExtras(exportTranscript: { log.add("export") }))
      defer { window.close() }
      let menu = try titleMenu()
      defer { menu.close() }
      try menu.clickControl(at: 1)
      #expect(log.entries == ["export"])
    }

    @Test("A sub-agent's menu goes to its parent, and a worker's to what created it")
    func goToOrigins() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.openSession = { log.add("open \($0)") }
      var state = conversation()
      state.header.settings = SessionSettings(parentId: "parent")
      let window = try await screen(
        state, actions: actions,
        extras: ConversationExtras(
          menuContext: SessionMenuContext(createdBy: CreatingSession(id: "boss", title: "Boss"))))
      defer { window.close() }
      let menu = try titleMenu()
      defer { menu.close() }
      #expect(try menu.shows("Go to Parent Session"))
      #expect(try menu.shows("Go to Creating Session"))
      try menu.clickControl(at: 1)
      try menu.clickControl(at: 2)
      #expect(log.entries == ["open parent", "open boss"])
    }

    @Test("A compact window's menu offers Chat or Terminal and the panels")
    func compactItems() async throws {
      let state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")], terminal: .ready)
      let window = try await screen(state, layout: .compact)
      defer { window.close() }
      let items = try #require(box.items)
      let menu = transcriptScreen(VStack { items.titleMenu }, height: 600, layout: .compact)
      defer { menu.close() }
      #expect(try menu.shows("Terminal"))
      #expect(try menu.shows("Files"))
    }

    @Test("The session menu's Rename asks for a name")
    func renameFromMenu() async throws {
      var sessionActions = SessionListActions()
      let log = self.log
      sessionActions.rename = { log.add("rename \($0.id) to \($1)") }
      let window = try await screen(
        conversation(summary: summary), extras: ConversationExtras(sessionActions: sessionActions))
      defer { window.close() }
      let menu = try titleMenu()
      defer { menu.close() }
      #expect(try menu.shows("Rename\u{2026}"))
      try menu.clickControl(at: 0)
      try await letTasksRun(window)
      #expect(log.entries == ["rename session-1 to A session"])
    }

    @Test("The session menu's Delete confirms first, then deletes")
    func deleteFromMenu() async throws {
      var sessionActions = SessionListActions()
      let log = self.log
      sessionActions.delete = { log.add("delete \($0.id)") }
      let window = try await screen(
        conversation(summary: summary), extras: ConversationExtras(sessionActions: sessionActions))
      defer { window.close() }
      let menu = try titleMenu()
      defer { menu.close() }
      try menu.clickControl(at: 0)
      try await letTasksRun(window)
      #expect(log.entries == ["delete session-1"])
    }

    @Test("Deleting a session with a worktree branch offers to delete the branch too")
    func deleteWithBranch() async throws {
      var sessionActions = SessionListActions()
      sessionActions.delete = { _ in }
      sessionActions.deleteWithBranch = { _, _ in }
      let window = try await screen(
        conversation(summary: summary),
        extras: ConversationExtras(
          sessionActions: sessionActions, menuContext: SessionMenuContext(branch: "feature/x")))
      defer { window.close() }
      let menu = try titleMenu()
      defer { menu.close() }
      try menu.clickControl(at: 0)
      try await letTasksRun(window)
      #expect(window.window.attachedSheet != nil)
      #expect(try window.shows("feature/x"))
    }

    @Test("A shared session is left, not deleted")
    func leaveFromMenu() async throws {
      var sessionActions = SessionListActions()
      let log = self.log
      sessionActions.leave = { log.add("leave \($0.id)") }
      let window = try await screen(
        conversation(summary: summary),
        extras: ConversationExtras(
          sessionActions: sessionActions, menuContext: SessionMenuContext(isShared: true)))
      defer { window.close() }
      let menu = try titleMenu()
      defer { menu.close() }
      try menu.clickControl(at: 0)
      try await letTasksRun(window)
      #expect(log.entries == ["leave session-1"])
    }

    @Test("Share opens the sheet and tells the host to read the grants")
    func shareSheet() async throws {
      let log = self.log
      let window = try await screen(
        conversation(summary: summary),
        extras: ConversationExtras(
          share: (state: ShareViewState(), actions: ShareActions()),
          shareOpened: { log.add("share opened") }))
      defer { window.close() }
      try #require(box.items).showShare()
      try await letTasksRun(window)
      #expect(window.window.attachedSheet != nil)
      #expect(log.entries == ["share opened"])
    }

    @Test("A fork in progress shows its dialog")
    func forkSheet() async throws {
      let fork = ForkViewState(
        id: "f", kind: .anotherDirectory, agents: [], agentID: "", directory: "/work")
      let window = try await screen(
        conversation(),
        extras: ConversationExtras(forkActions: ForkActions(forkWith: { _ in }, cancel: {})),
        fork: fork)
      defer { window.close() }
      #expect(window.window.attachedSheet != nil)
    }
  }
#endif
