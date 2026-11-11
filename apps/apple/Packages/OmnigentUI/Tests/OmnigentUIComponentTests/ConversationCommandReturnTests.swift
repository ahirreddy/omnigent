#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A conversation whose draft the host hands on without reading it, as the app does: only the
  /// composer renders for a keystroke, so nothing above it covers for a stale Send or Approve.
  @MainActor
  @Observable
  private final class CommandReturnModel {
    var state: ConversationViewState
    var composer = ComposerViewState()
    var draft = ""
    /// The commands the menus would run.
    @ObservationIgnored var commands: SessionCommandActions?
    /// How many times the menus were handed commands to rebuild from.
    @ObservationIgnored var publications = 0

    init(_ state: ConversationViewState) {
      self.state = state
    }
  }

  /// Reads the published commands as the app's menu bar does.
  private struct CommandReturnProbe: View {
    let model: CommandReturnModel
    @FocusedValue(\.sessionCommands) private var commands

    var body: some View {
      model.commands = commands
      model.publications += 1
      return Color.clear.frame(width: 1, height: 1)
    }
  }

  private struct CommandReturnHost: View {
    let model: CommandReturnModel
    let actions: ConversationActions
    let composerActions: ComposerActions

    var body: some View {
      ZStack {
        ConversationScreen(
          state: model.state, composer: model.composer,
          draft: ComposerDraft(get: { model.draft }, set: { model.draft = $0 }),
          showsInspector: .constant(false), mode: .constant(.chat), actions: actions,
          composerActions: composerActions
        ) {
          EmptyView()
        }
        CommandReturnProbe(model: model)
      }
    }
  }

  /// Who answers Command-Return as the draft gains and loses its text, which the conversation
  /// reads below its own body.
  @Suite("Conversation Command-Return", .serialized)
  @MainActor
  struct ConversationCommandReturnTests {
    private let log = DecisionDockLog()
    private let sent = HostLog()

    private func open(
      _ model: CommandReturnModel, extras: ComposerExtraActions = ComposerExtraActions()
    ) async throws -> OffscreenWindow<AnyView> {
      let sent = self.sent
      let window = transcriptScreen(
        CommandReturnHost(
          model: model, actions: log.actions,
          composerActions: ComposerActions(send: { sent.add("send") }, extras: extras)),
        width: 900, height: 600)
      try await letTasksRun(window, milliseconds: 200)
      return window
    }

    private func pressCommandReturn(_ window: OffscreenWindow<AnyView>) throws {
      _ = try window.pressShortcut(
        keyCode: ComposerKey.returnKey, characters: "\r", modifiers: .command)
    }

    private func waiting() -> CommandReturnModel {
      CommandReturnModel(.requests([.sample(id: "one", detail: "Do one")]))
    }

    /// The Approve button names the shortcut while it owns it.
    private static let shortcutHint = "\u{2318}\u{21A9}"

    @Test("Command-Return approves the request until a draft waits, then sends it")
    func draftTakesCommandReturn() async throws {
      let model = waiting()
      let window = try await open(model)
      defer { window.close() }
      #expect(try window.shows(Self.shortcutHint))
      #expect(model.commands?.approveOwnsCommandReturn == true)
      #expect(model.commands?.send == nil)
      try pressCommandReturn(window)
      #expect(log.responses == ["one:Approved"])
      #expect(sent.entries.isEmpty)

      let published = model.publications
      model.draft = "A reply"
      try await letTasksRun(window)
      #expect(model.publications > published, "the menus hear that Send took the key")
      #expect(try !window.shows(Self.shortcutHint))
      #expect(model.commands?.approveOwnsCommandReturn == false)
      #expect(model.commands?.send != nil)
      try pressCommandReturn(window)
      #expect(log.responses == ["one:Approved"], "the draft owns the key, so nothing more approves")
      #expect(sent.entries == ["send"])

      model.draft = ""
      try await letTasksRun(window)
      #expect(try window.shows(Self.shortcutHint))
      #expect(model.commands?.approveOwnsCommandReturn == true)
      #expect(model.commands?.send == nil)
    }

    @Test("Emptying the draft gives Command-Return back to the request")
    func emptiedDraftGivesItBack() async throws {
      let model = waiting()
      model.draft = "A reply"
      let window = try await open(model)
      defer { window.close() }
      #expect(try !window.shows(Self.shortcutHint))
      #expect(model.commands?.send != nil)

      model.draft = "  "
      try await letTasksRun(window)
      #expect(try window.shows(Self.shortcutHint))
      #expect(model.commands?.send == nil)
      try pressCommandReturn(window)
      #expect(log.responses == ["one:Approved"])
      #expect(sent.entries.isEmpty)
    }

    @Test("Something attached can go without text; a composer that cannot send offers nothing")
    func attachedContentAndClosedSend() async throws {
      let model = waiting()
      model.composer.mentions = ["Sources/App.swift"]
      let window = try await open(model)
      defer { window.close() }
      #expect(model.commands?.send != nil)
      #expect(model.commands?.approveOwnsCommandReturn == false)

      model.composer.delivery = .sending
      model.draft = "A reply"
      try await letTasksRun(window)
      #expect(model.commands?.send == nil, "a message is on its way")
      #expect(model.commands?.approveOwnsCommandReturn == true)
    }

    @Test("With no request waiting, a draft's first and last key leave the menus alone")
    func noRequestNothingRepublished() async throws {
      let model = CommandReturnModel(
        ConversationViewState(header: SessionHeader(id: "session", title: "Session")))
      let window = try await open(model)
      defer { window.close() }
      #expect(model.commands?.approveOwnsCommandReturn == false)
      let send = try #require(model.commands?.send)
      send()
      #expect(sent.entries.isEmpty, "an empty draft is not sent")

      let published = model.publications
      for text in ["k", "", "  "] {
        model.draft = text
        try await letTasksRun(window)
        #expect(model.publications == published, "\(text.debugDescription)")
      }
      try pressCommandReturn(window)
      #expect(sent.entries.isEmpty, "a blank draft is not sent")

      model.draft = "A reply"
      try await letTasksRun(window)
      #expect(model.publications == published)
      try pressCommandReturn(window)
      #expect(sent.entries == ["send"])

      model.composer.delivery = .sending
      try await letTasksRun(window)
      #expect(model.commands?.send == nil, "a message is on its way")
    }

    @Test("With a queue to wait in, Send Message stays while a message is on its way")
    func sendStaysDuringASend() async throws {
      let model = CommandReturnModel(
        ConversationViewState(header: SessionHeader(id: "session", title: "Session")))
      model.draft = "And this"
      let window = try await open(model, extras: ComposerExtraActions(queueDraft: {}))
      defer { window.close() }

      for delivery in [DeliveryState.sending, .failed(message: "Refused")] {
        model.composer.delivery = delivery
        try await letTasksRun(window)
        #expect(model.commands?.send != nil, "\(delivery)")
      }
      model.composer.delivery = .sending
      try await letTasksRun(window)
      try pressCommandReturn(window)
      #expect(sent.entries == ["send"])

      model.composer.delivery = .uncertain(message: "Unclear")
      try await letTasksRun(window)
      #expect(model.commands?.send == nil, "an unclear send is reviewed first")
    }

    #if DEBUG
      @Test("A draft's first and last key render the composer, not the conversation above it")
      func firstKeyLeavesTheScreen() async throws {
        let model = waiting()
        model.state.rows = [TranscriptFixture.answer("a", "Hello there")]
        let window = try await open(model)
        defer { window.close() }
        #expect(model.commands?.send == nil)

        for (text, sends) in [("k", true), ("", false)] {
          let renders = RenderTally.recording {
            model.draft = text
            window.settle(0.2)
          }
          let above = renders.filter { ["screen", "transcript", "rows", "row"].contains($0.key) }
          #expect(above.isEmpty, "\(text.isEmpty ? "emptied" : "typed"): \(renders)")
          try await letTasksRun(window)
          #expect((model.commands?.send != nil) == sends)
          #expect(try window.shows(Self.shortcutHint) == !sends)
        }
      }
    #endif
  }
#endif
