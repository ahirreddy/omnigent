#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A new session's row of choices on the Mac, the name under its composer and its width.
  @Suite("New session: agent, model, effort and name", .serialized)
  @MainActor
  struct NewSessionStartMenusTests {
    private let log = ComposerActionLog()

    private func menus(_ configuration: ComposerConfiguration) -> OffscreenWindow<some View> {
      let screen = OffscreenWindow(
        ConfigurationMenu(configuration: configuration, actions: log.actions, showsAgent: true)
          .environment(\.composerLayoutStyle, .card),
        width: 600, height: 80)
      screen.settle()
      return screen
    }

    private func menu(_ index: Int, in screen: OffscreenWindow<some View>) throws -> NSMenu {
      let frames = screen.controlFrames
      let frame = try #require(frames.indices.contains(index) ? frames[index] : nil)
      return try screen.openMenu(screen.clickPoint(frame))
    }

    /// One menu of a fresh row: a second menu opened in the same window does not open while
    /// AppKit is still ending the first one's tracking.
    private func opened(_ index: Int) throws -> (NSMenu, OffscreenWindow<some View>) {
      let screen = menus(ComposerSamples.codexConfiguration)
      #expect(screen.controlFrames.count == 3)
      return (try menu(index, in: screen), screen)
    }

    @Test("The agent's menu offers agents and nothing of models or efforts")
    func agentMenu() throws {
      let (agents, screen) = try opened(0)
      defer { screen.close() }
      #expect(agents.titles.contains("Claude Code"))
      #expect(!agents.titles.contains("GPT-5.2"))
      #expect(!agents.titles.contains("Low"))
      try screen.choose("Claude Code", in: agents)
      #expect(log.events == ["agent:agent_claude"])
    }

    @Test("The model's menu offers the agent's models and nothing else")
    func modelMenu() throws {
      let (models, screen) = try opened(1)
      defer { screen.close() }
      #expect(!models.titles.contains("Claude Code"))
      #expect(!models.titles.contains("Low"))
      try screen.choose("GPT-5.2", in: models)
      #expect(log.events == ["model:gpt-5.2"])
    }

    @Test("The effort's menu offers the model's efforts and nothing else")
    func effortMenu() throws {
      let (efforts, screen) = try opened(2)
      defer { screen.close() }
      #expect(!efforts.titles.contains("GPT-5.2"))
      #expect(!efforts.titles.contains("Claude Code"))
      try screen.choose("Low", in: efforts)
      #expect(log.events == ["effort:low"])
    }

    @Test("With no models to offer, as before a list arrives, only the agent's menu shows")
    func agentAlone() throws {
      var configuration = ComposerSamples.codexConfiguration
      configuration.modelOptions = []
      let screen = menus(configuration)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 1)
      #expect(try screen.shows(configuration.agentTitle))
    }

    @Test("A busy session's menus say why and take no choice; a failed model list says so")
    func busyAndFailed() throws {
      var busy = ComposerSamples.codexConfiguration
      busy.busyReason = "Wait for the turn to finish."
      let waiting = menus(busy)
      defer { waiting.close() }
      let agents = try menu(0, in: waiting)
      #expect(agents.titles.contains("Wait for the turn to finish."))
      #expect(agents.items.first { $0.title == "Claude Code" }?.isEnabled == false)

      var applying = ComposerSamples.codexConfiguration
      applying.isApplying = true
      let spinning = menus(applying)
      defer { spinning.close() }
      #expect(spinning.allViews.contains { $0 is NSProgressIndicator })

      var failed = ComposerSamples.codexConfiguration
      failed.errorMessage = "Models unavailable"
      let broken = menus(failed)
      defer { broken.close() }
      #expect(!broken.allViews.contains { $0 is NSProgressIndicator })
      #expect(broken.controlFrames.count == 3)
    }

    @Test("Smart Routing takes the effort's place, and its menu still offers the models")
    func smartRouting() throws {
      var routed = ComposerSamples.codexConfiguration
      routed.smartRouting = .enabled
      let screen = menus(routed)
      defer { screen.close() }
      #expect(try screen.shows(ComposerConfiguration.smartRoutingTitle))
      var offered = ComposerSamples.codexConfiguration
      offered.modelOptions = []
      offered.smartRouting = .disabled
      let alone = menus(offered)
      defer { alone.close() }
      #expect(alone.controlFrames.count == 2, "the agent, and a model menu for the toggle")
    }

    @Test(
      "The name field under the composer reports what is typed, and is absent without a handler")
    func nameField() throws {
      var typed: [String] = []
      var actions = NewSessionOptionActions()
      actions.setName = { typed.append($0) }
      var options = NewSessionOptions()
      options.name = "Night"
      let screen = OffscreenWindow(
        NewSessionOptionsBar(options: options, actions: actions), width: 600, height: 60)
      defer { screen.close() }
      let field = try #require(Self.editableFields(screen).first)
      #expect(field.stringValue == "Night")
      try screen.click(field)
      try screen.type("!")
      #expect(typed.last?.contains("!") == true)

      let plain = OffscreenWindow(
        NewSessionOptionsBar(options: options, actions: NewSessionOptionActions()),
        width: 600, height: 60)
      defer { plain.close() }
      #expect(Self.editableFields(plain).isEmpty)
    }

    /// The fields a person can type in; a menu button's title is a text field too.
    private static func editableFields(_ screen: OffscreenWindow<some View>) -> [NSTextField] {
      screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
    }

    @Test("In a wide window the composer keeps to a column in the middle")
    func composerWidth() throws {
      let screen = OffscreenWindow(
        NewSessionPage(
          draft: .constant(""), composer: ComposerViewState(purpose: .start),
          actions: log.actions),
        width: 1_800, height: 700)
      defer { screen.close() }
      let editor = try #require(screen.allViews.first { $0 is NSTextView })
      let frame = editor.convert(editor.bounds, to: screen.activeWindow.contentView)
      #expect(frame.width <= NewSessionPage.composerWidth)
      #expect(abs(frame.midX - 900) < 40, "centered in the window")
    }

    @Test("Each approval level's symbol has its own color in the Mac's row")
    func approvalColors() {
      let colors = [ApprovalRisk.readOnly, .ask, .autoEdit, .autoApprove, .fullAccess]
        .map(\.symbolColor)
      #expect(Set(colors).count == colors.count)
      #expect(ApprovalRisk.fullAccess.symbolColor == Theme.warning)
    }
  }
#endif
