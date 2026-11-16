#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What a conversation's panel, mode and composer would be in the app.
  @MainActor
  @Observable
  private final class CommandScreenModel {
    var state: ConversationViewState
    var composer = ComposerViewState()
    var mode = SessionViewMode.chat
    var showsInspector = false
    var inspectorTab = InspectorTab.files
    var draft = ""

    init(_ state: ConversationViewState) {
      self.state = state
    }
  }

  /// The Navigate and Conversation menus as the menu bar builds them, over whatever the window's
  /// conversation publishes, so a key equivalent reaches the screen the way it does in the app.
  private struct MenuBarStandIn: View {
    @FocusedValue(\.sessionCommands) private var session
    @FocusedValue(\.paletteCommands) private var palette

    var body: some View {
      Menu("Menu bar") {
        NavigateMenuItems(palette: palette)
        ConversationMenuItems(actions: session)
      }
      .frame(width: 140, height: 28)
    }
  }

  private struct CommandScreenHost: View {
    @Bindable var model: CommandScreenModel
    let composerActions: ComposerActions
    let extras: ConversationExtras

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        MenuBarStandIn()
        ConversationScreen(
          state: model.state, composer: model.composer, draft: ComposerDraft($model.draft),
          showsInspector: $model.showsInspector, inspectorTab: $model.inspectorTab,
          mode: $model.mode, actions: ConversationActions(), composerActions: composerActions,
          extras: extras
        ) {
          Text("the terminal surface")
        }
      }
      .commandPalette(
        state: PaletteViewState(scope: "Studio", sessions: [], servers: [], hasNextRequest: false),
        actions: PaletteActions { _ in })
    }
  }

  /// The menus' keys, pressed over a mounted conversation, and what each does to it.
  @Suite("Conversation screen: menu keys", .serialized)
  @MainActor
  struct ConversationMenuCommandTests {
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private func screen(
      _ model: CommandScreenModel, composerActions: ComposerActions? = nil,
      extras: ConversationExtras = ConversationExtras()
    ) async throws -> OffscreenWindow<AnyView> {
      let window = transcriptScreen(
        CommandScreenHost(
          model: model, composerActions: composerActions ?? ComposerActions(send: {}),
          extras: extras),
        width: 900, height: 640)
      try await letTasksRun(window, milliseconds: 200)
      return window
    }

    private func chat(
      rows: [Row] = [TranscriptFixture.answer("a", "Hello there")], terminal: TerminalStatus = .none
    ) -> CommandScreenModel {
      CommandScreenModel(
        ConversationViewState(header: TranscriptFixture.header, rows: rows, terminal: terminal))
    }

    /// The stand-in menu bar: the window's topmost menu.
    private func menuBar(_ window: OffscreenWindow<AnyView>) throws -> NSMenu {
      try window.menu(at: 0)
    }

    /// Whether the menu item titled `title` can be chosen now.
    private func isEnabled(_ title: String, on window: OffscreenWindow<AnyView>) throws -> Bool {
      let menu = try menuBar(window)
      return try #require(menu.items.first { $0.title == title }, "no item titled \(title)")
        .isEnabled
    }

    /// Presses the key equivalent of the menu item titled `title`, as the menu bar matches a key
    /// before any view sees it.
    /// - Returns: Whether an item has that key; a disabled item still matches and does nothing.
    private func pressKey(
      of title: String, on window: OffscreenWindow<AnyView>
    ) async throws -> Bool {
      let menu = try menuBar(window)
      let item = try #require(menu.items.first { $0.title == title }, "no item titled \(title)")
      try #require(!item.keyEquivalent.isEmpty, "\(title) has no key")
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: item.keyEquivalentModifierMask,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.window.windowNumber,
        context: nil, characters: item.keyEquivalent,
        charactersIgnoringModifiers: item.keyEquivalent, isARepeat: false, keyCode: 0)
      let handled = menu.performKeyEquivalent(with: try #require(event))
      try await letTasksRun(window)
      return handled
    }

    @Test("Option-Command-I shows and hides the right panel")
    func rightPanelKey() async throws {
      let model = chat()
      let window = try await screen(model)
      defer { window.close() }
      #expect(try await pressKey(of: "Toggle Right Panel", on: window))
      #expect(model.showsInspector)
      #expect(try await pressKey(of: "Toggle Right Panel", on: window))
      #expect(!model.showsInspector)
    }

    @Test("Option-Command-Backslash swaps chat for the terminal, where the composer keys are off")
    func viewModeKey() async throws {
      let model = chat(terminal: .ready)
      let window = try await screen(model)
      defer { window.close() }
      #expect(try await pressKey(of: "Toggle Chat and Terminal", on: window))
      #expect(model.mode == .terminal)
      #expect(try window.shows("the terminal surface"))
      // The terminal has no composer to focus and no transcript to jump in.
      #expect(try isEnabled("Focus Composer", on: window) == false)
      #expect(try isEnabled("Jump to Latest", on: window) == false)
      #expect(try await pressKey(of: "Toggle Chat and Terminal", on: window))
      #expect(model.mode == .chat)
      #expect(try !window.shows("the terminal surface"))
    }

    @Test("Without a terminal the view key does nothing")
    func viewModeKeyWithoutTerminal() async throws {
      let model = chat()
      let window = try await screen(model)
      defer { window.close() }
      #expect(try isEnabled("Toggle Chat and Terminal", on: window) == false)
      _ = try await pressKey(of: "Toggle Chat and Terminal", on: window)
      #expect(model.mode == .chat)
      #expect(try !window.shows("the terminal surface"))
    }

    @Test("Control-Shift-L gives the composer the keyboard")
    func focusComposerKey() async throws {
      let model = chat()
      let window = try await screen(model)
      defer { window.close() }
      window.window.makeFirstResponder(nil)
      window.settle()
      #expect(!(window.window.firstResponder is NSTextView))
      #expect(try await pressKey(of: "Focus Composer", on: window))
      #expect(await window.waitUntil { window.window.firstResponder is NSTextView })
    }

    @Test("Command-Down goes to the newest message from the top of a long transcript")
    func jumpToLatestKey() async throws {
      let model = chat(rows: TranscriptFixture.turns(8))
      let window = try await screen(model)
      defer { window.close() }
      try await letOpeningEnd(window)
      let viewport = TranscriptScrollDriver(screen: window)
      // The reader scrolls up to the first message, as a trackpad gesture does.
      let scroll = try #require(viewport.scrollView)
      window.liveScroll(scroll, began: true)
      viewport.move(to: 0)
      window.liveScroll(scroll, began: false)
      let start = viewport.offset
      try #require(
        viewport.maximumOffset - start > 300,
        "the reader is at \(start) of \(viewport.maximumOffset), not above the newest message")
      #expect(try await pressKey(of: "Jump to Latest", on: window))
      #expect(
        await window.waitUntil { viewport.offset > start + 200 }, "at \(viewport.offset)")
    }

    private func modelChoices() -> (CommandScreenModel, ComposerActions) {
      let model = chat()
      model.composer.configuration = ComposerConfiguration(
        modelOptions: [
          ModelOption(id: "fast", supportedReasoningEfforts: ["low", "high"]),
          ModelOption(id: "deep"),
        ],
        selectedModelId: "fast", selectedEffort: "low")
      let log = self.log
      let actions = ComposerActions(
        send: {}, selectModel: { log.add("model \($0 ?? "default")") },
        selectEffort: { log.add("effort \($0 ?? "default")") })
      return (model, actions)
    }

    @Test("Control-Option-M and Control-Option-E move to the next model and the next effort")
    func cycleKeys() async throws {
      let (model, actions) = modelChoices()
      let window = try await screen(model, composerActions: actions)
      defer { window.close() }
      #expect(try await pressKey(of: "Next Model", on: window))
      #expect(try await pressKey(of: "Next Reasoning Effort", on: window))
      #expect(log.entries == ["model deep", "effort high"])
    }

    @Test("Control-Shift-M asks which model, and takes the answer; Cancel takes none")
    func chooseModelKey() async throws {
      let (model, actions) = modelChoices()
      let window = try await screen(model, composerActions: actions)
      defer { window.close() }
      // The dialog's buttons: the default, each model, then Cancel.
      let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      #expect(try await pressKey(of: "Choose Model\u{2026}", on: window))
      #expect(await window.waitUntil { SystemSideEffects.record.alertMessages == ["Model"] })
      #expect(await window.waitUntil { log.entries == ["model fast"] }, "\(log.entries)")

      SystemSideEffects.answer(alert: NSApplication.ModalResponse(rawValue: first + 3))
      #expect(try await pressKey(of: "Choose Model\u{2026}", on: window))
      #expect(
        await window.waitUntil { SystemSideEffects.record.alertMessages.count == 2 })
      try await letTasksRun(window, milliseconds: 200)
      #expect(log.entries == ["model fast"], "Cancel chooses nothing")
    }

    private func renaming() -> (CommandScreenModel, ConversationExtras) {
      let model = chat()
      model.state.summary = SessionSummary(id: "session-1", title: "Old name")
      var sessionActions = SessionListActions()
      let log = self.log
      sessionActions.rename = { log.add("rename \($0.id) to \($1)") }
      return (model, ConversationExtras(sessionActions: sessionActions))
    }

    @Test("Option-Command-R asks for a name and renames to it")
    func renameKey() async throws {
      let (model, extras) = renaming()
      let window = try await screen(model, extras: extras)
      defer { window.close() }
      #expect(try await pressKey(of: "Rename Session\u{2026}", on: window))
      #expect(
        await window.waitUntil { log.entries == ["rename session-1 to Old name"] },
        "\(log.entries) \(SystemSideEffects.record.alertMessages)")
      #expect(SystemSideEffects.record.alertMessages == ["Rename Session"])
    }

    @Test("Cancel in the rename dialog renames nothing")
    func renameKeyCancelled() async throws {
      let (model, extras) = renaming()
      let window = try await screen(model, extras: extras)
      defer { window.close() }
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      #expect(try await pressKey(of: "Rename Session\u{2026}", on: window))
      #expect(
        await window.waitUntil {
          SystemSideEffects.record.alertMessages == ["Rename Session"]
        })
      try await letTasksRun(window, milliseconds: 200)
      #expect(log.entries.isEmpty)
    }

    @Test("Open Changes, run from the palette Command-K opens, shows the panel on Changes")
    func openChangesFromThePalette() async throws {
      let model = chat()
      let window = try await screen(model)
      defer { window.close() }
      #expect(try await pressKey(of: "Command Palette\u{2026}", on: window))
      #expect(await window.waitUntil { window.window.attachedSheet != nil })
      try window.type("Open Changes")
      try window.press(keyCode: 36, characters: "\r")
      #expect(await window.waitUntil { window.window.attachedSheet == nil })
      #expect(await window.waitUntil { model.showsInspector })
      #expect(model.inspectorTab == .changes)
    }
  }
#endif
