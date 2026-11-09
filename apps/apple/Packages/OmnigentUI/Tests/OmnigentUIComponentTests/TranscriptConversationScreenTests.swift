#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What a screen's view modes, panel and composer would be in the app.
  @MainActor
  @Observable
  private final class ScreenModel {
    var state: ConversationViewState
    var composer = ComposerViewState()
    var mode = SessionViewMode.chat
    var showsInspector = false
    var draft = ""
    /// The commands the menus would run.
    @ObservationIgnored var commands: SessionCommandActions?

    init(_ state: ConversationViewState) {
      self.state = state
    }
  }

  /// Reads the published commands as the app's menu bar does.
  private struct CommandsProbe: View {
    let model: ScreenModel
    @FocusedValue(\.sessionCommands) private var commands

    var body: some View {
      model.commands = commands
      return Color.clear.frame(width: 1, height: 1)
    }
  }

  private struct ScreenHost: View {
    @Bindable var model: ScreenModel
    let actions: ConversationActions
    let composerActions: ComposerActions
    let extras: ConversationExtras

    var body: some View {
      ZStack {
        ConversationScreen(
          state: model.state, composer: model.composer, draft: ComposerDraft($model.draft),
          showsInspector: $model.showsInspector, mode: $model.mode, actions: actions,
          composerActions: composerActions, extras: extras
        ) {
          Text("the terminal surface")
        }
        CommandsProbe(model: model)
      }
    }
  }

  @Suite("Conversation screen", .serialized)
  @MainActor
  struct TranscriptConversationScreenTests {
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private func screen(
      _ model: ScreenModel, actions: ConversationActions = ConversationActions(),
      composerActions: ComposerActions? = nil, extras: ConversationExtras = ConversationExtras()
    ) async throws -> OffscreenWindow<AnyView> {
      let log = self.log
      let window = transcriptScreen(
        ScreenHost(
          model: model, actions: actions,
          composerActions: composerActions ?? ComposerActions(send: { log.add("send") }),
          extras: extras),
        width: 900, height: 600)
      try await letTasksRun(window, milliseconds: 200)
      return window
    }

    private func chat(terminal: TerminalStatus = .none) -> ScreenModel {
      ScreenModel(
        ConversationViewState(
          header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a", "Hello there")],
          terminal: terminal))
    }

    @Test("Chat shows the transcript and composer; Terminal swaps both for the terminal")
    func modes() async throws {
      let model = chat(terminal: .ready)
      let window = try await screen(model)
      defer { window.close() }
      #expect(try window.shows("Hello there"))
      #expect(window.allViews.contains { $0 is NSTextView })
      #expect(try !window.shows("the terminal surface"))

      model.mode = .terminal
      try await letTasksRun(window)
      #expect(try window.shows("the terminal surface"))
      #expect(!window.allViews.contains { $0 is NSTextView })
    }

    @Test("A session without a terminal stays in chat whatever the mode says")
    func terminalMode() async throws {
      let model = chat()
      model.mode = .terminal
      let window = try await screen(model)
      defer { window.close() }
      #expect(try window.shows("Hello there"))
      #expect(try !window.shows("the terminal surface"))
    }

    // MARK: Where a session came from

    @Test("A side chat links back to the chat it came from")
    func sideChatOrigin() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.openSession = { log.add("open \($0)") }
      let model = chat()
      model.state.header.settings = SessionSettings(sideChatSourceId: "source")
      let window = try await screen(
        model, actions: actions,
        extras: ConversationExtras(
          menuContext: SessionMenuContext(parent: CreatingSession(id: "source", title: "Parent"))))
      defer { window.close() }
      #expect(try window.shows("Parent"))
      let bar = try #require(window.controlFrames.first)
      try window.click(CGPoint(x: bar.midX, y: bar.midY))
      #expect(log.entries == ["open source"])
    }

    @Test("A sub-agent links to its parent, and a worker to what started it")
    func otherOrigins() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.openSession = { log.add("open \($0)") }
      let subagent = chat()
      subagent.state.header.settings = SessionSettings(parentId: "parent")
      let window = try await screen(subagent, actions: actions)
      defer { window.close() }
      let bar = try #require(window.controlFrames.first)
      try window.click(CGPoint(x: bar.midX, y: bar.midY))
      #expect(log.entries == ["open parent"])

      let worker = try await screen(
        chat(), actions: actions,
        extras: ConversationExtras(
          menuContext: SessionMenuContext(createdBy: CreatingSession(id: "boss", title: "Boss"))))
      defer { worker.close() }
      #expect(try worker.shows("Boss"))
      let workerBar = try #require(worker.controlFrames.first)
      try worker.click(CGPoint(x: workerBar.midX, y: workerBar.midY))
      #expect(log.entries == ["open parent", "open boss"])
    }

    // MARK: Menu commands

    @Test("The menu commands toggle the panel and mode, and focus the composer")
    func commands() async throws {
      let model = chat(terminal: .ready)
      let window = try await screen(model)
      defer { window.close() }
      let commands = try #require(model.commands)
      commands.toggleInspector?()
      try await letTasksRun(window)
      #expect(model.showsInspector)
      commands.toggleInspector?()
      try await letTasksRun(window)
      #expect(!model.showsInspector)

      commands.openChanges?()
      try await letTasksRun(window)
      #expect(model.showsInspector)

      commands.toggleViewMode?()
      try await letTasksRun(window)
      #expect(model.mode == .terminal)
      // The terminal has no composer to send from or to jump in.
      let inTerminal = try #require(model.commands)
      #expect(inTerminal.jumpToLatest == nil)
      #expect(inTerminal.focusComposer == nil)
    }

    @Test("Send is offered only while the draft can go")
    func sendCommand() async throws {
      let model = chat()
      let window = try await screen(model)
      defer { window.close() }
      #expect(model.commands?.send == nil)
      model.draft = "A message"
      try await letTasksRun(window)
      let send = try #require(model.commands?.send)
      send()
      #expect(log.entries == ["send"])
      model.draft = "   "
      try await letTasksRun(window)
      #expect(model.commands?.send == nil)
    }

    @Test("With messages queued, the send command sends them all with the draft")
    func sendAllQueued() async throws {
      let model = chat()
      model.composer.queue = [QueuedMessage(id: "q", text: "Later")]
      model.draft = "Now"
      var extras = ComposerExtraActions()
      let log = self.log
      extras.queueDraft = { log.add("queue draft") }
      extras.history.sendAllQueued = { log.add("send all") }
      let window = try await screen(
        model, composerActions: ComposerActions(send: { log.add("send") }, extras: extras))
      defer { window.close() }
      let send = try #require(model.commands?.send)
      send()
      #expect(log.entries == ["queue draft", "send all"])
    }

    @Test("Interrupt is there only while a turn runs")
    func interruptCommand() async throws {
      let model = chat()
      let log = self.log
      let actions = ComposerActions(send: {}, interrupt: { log.add("interrupt") })
      let window = try await screen(model, composerActions: actions)
      defer { window.close() }
      #expect(model.commands?.interrupt == nil)
      model.composer.isRunning = true
      try await letTasksRun(window)
      model.commands?.interrupt?()
      #expect(log.entries == ["interrupt"])
    }

    @Test("Next Model and Next Effort follow the session's choices")
    func modelCommands() async throws {
      let model = chat()
      model.composer.configuration = ComposerConfiguration(
        modelOptions: [
          ModelOption(id: "fast", supportedReasoningEfforts: ["low", "high"]),
          ModelOption(id: "deep"),
        ],
        selectedModelId: "fast", selectedEffort: "low")
      let log = self.log
      let window = try await screen(
        model,
        composerActions: ComposerActions(
          send: {}, selectModel: { log.add("model \($0 ?? "")") },
          selectEffort: { log.add("effort \($0 ?? "")") }))
      defer { window.close() }
      let commands = try #require(model.commands)
      commands.cycleModel?()
      commands.cycleEffort?()
      #expect(log.entries == ["model deep", "effort high"])
      #expect(commands.chooseModel != nil)
      commands.chooseModel?()
      try await letTasksRun(window)

      model.composer.configuration?.isApplying = true
      try await letTasksRun(window)
      #expect(model.commands?.cycleModel == nil)
    }

    @Test("Rename from the menu asks for the name, then renames")
    func renameCommand() async throws {
      let model = chat()
      model.state.summary = SessionSummary(id: "session-1", title: "Old name")
      var sessionActions = SessionListActions()
      let log = self.log
      sessionActions.rename = { log.add("rename \($0.id) to \($1)") }
      let window = try await screen(
        model, extras: ConversationExtras(sessionActions: sessionActions))
      defer { window.close() }
      let rename = try #require(model.commands?.rename)
      rename()
      try await letTasksRun(window)
      // The offscreen alert answers with its first button.
      #expect(log.entries == ["rename session-1 to Old name"])
    }

    @Test("Without a right to rename the command isn't offered")
    func renameUnavailable() async throws {
      let model = chat()
      model.state.summary = SessionSummary(id: "session-1", title: "Old", canRename: false)
      var sessionActions = SessionListActions()
      sessionActions.rename = { _, _ in }
      let window = try await screen(
        model, extras: ConversationExtras(sessionActions: sessionActions))
      defer { window.close() }
      #expect(model.commands?.rename == nil)
    }

    @Test("An inactive pane publishes no commands")
    func inactivePane() async throws {
      let model = chat()
      let window = transcriptScreen(
        ScreenHost(
          model: model, actions: ConversationActions(), composerActions: ComposerActions(send: {}),
          extras: ConversationExtras()
        )
        .environment(\.isActiveTabPane, false), width: 900, height: 600)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      #expect(model.commands == nil)
    }
  }
#endif
