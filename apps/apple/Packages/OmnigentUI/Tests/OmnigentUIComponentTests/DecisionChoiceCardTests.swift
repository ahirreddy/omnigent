#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Questions with fixed answers, plans, requests the app can't answer, and the keyboard.
  @Suite("Decision card: questions and plans", .serialized)
  @MainActor
  struct DecisionChoiceCardTests {
    private let log = DecisionResponseLog()

    private func open(
      _ card: DecisionCard, model: DecisionCardModel = DecisionCardModel()
    ) -> OffscreenWindow<DecisionCardScreen> {
      let screen = OffscreenWindow(DecisionCardScreen(card: card, model: model, log: log))
      screen.settle()
      return screen
    }

    private var question: DecisionCard {
      .sample(
        title: "Response requested", detail: "Which focus?",
        kind: .choice(answerKey: "focus", options: ["Speed", "Memory", "Size"]))
    }

    @Test("Each answer sends itself")
    func everyAnswer() throws {
      for (index, answer) in ["Speed", "Memory", "Size"].enumerated() {
        log.responses = []
        let screen = open(question)
        defer { screen.close() }
        #expect(try screen.shows("Choose an option"))
        #expect(try screen.shows("Which focus?"))
        #expect(try screen.shows(answer))
        try screen.tapButton(index)
        #expect(log.responses == [.answer(value: answer)])
      }
    }

    @Test("Cancel dismisses the question")
    func cancel() throws {
      let screen = open(question)
      defer { screen.close() }
      #expect(try screen.shows("Cancel"))
      try screen.tapButton(fromEnd: 0)
      #expect(log.responses == [.cancel])
    }

    @Test("A read-only question offers no answer")
    func readOnly() throws {
      let screen = open(question, model: DecisionCardModel(isReadOnly: true))
      defer { screen.close() }
      #expect(try screen.shows("Speed"))
      try screen.clickEveryButton()
      #expect(log.responses.isEmpty)
    }

    // MARK: Plans

    private func plan(_ permissions: PermissionOptions = PermissionOptions()) -> DecisionCard {
      var options = permissions
      options.plan = "# Steps\n\nFirst do this."
      return .sample(title: "Review the plan", permissions: options)
    }

    @Test("A plan shows its text, and Approve plan approves it")
    func planApprove() throws {
      let screen = open(plan())
      defer { screen.close() }
      #expect(try screen.shows("Plan review"))
      #expect(try screen.shows("First do this."))
      #expect(try screen.shows("Approve plan"))
      try screen.tapButton(0)
      #expect(log.responses == [.approve])
    }

    @Test("A plan asks what should change, and sends that on rejecting it")
    func planFeedback() throws {
      var card = plan()
      card.acceptsFeedback = true
      let screen = open(card)
      defer { screen.close() }
      try screen.tapButton(2)
      #expect(try screen.shows("What should change about the plan?"))
      try screen.type("Fewer steps", intoField: 0)
      screen.settle(0.05)
      try screen.tapButton(fromEnd: 1)
      #expect(log.responses == [.declineWithFeedback(feedback: "Fewer steps")])
    }

    @Test("A plan offers auto mode alone, whichever flag allows it")
    func planAutoMode() throws {
      SystemSideEffects.reset()
      for (options, response) in [
        (PermissionOptions(allowAllEdits: true), DecisionResponse.approveAllEdits),
        (PermissionOptions(allowAutoMode: true), .approveAutoMode),
      ] {
        log.responses = []
        let screen = open(plan(options))
        defer { screen.close() }
        let menu = try screen.menu(at: 0)
        #expect(menuTitles(menu) == ["Approve and use auto mode for this session"])
        try screen.choose("Approve and use auto mode for this session", in: menu)
        screen.settle(0.3)
        #expect(log.responses == [response])
      }
    }

    // MARK: Unsupported

    @Test("A request the app can't answer says why and opens its page")
    func unsupported() throws {
      let card = DecisionCard.sample(
        title: "Sign in", detail: "Needs a browser",
        kind: .unsupported(reason: "Finish this in the browser", externalUrl: "https://a.test/ok"))
      let screen = open(card)
      defer { screen.close() }
      #expect(try screen.shows("Sign in"))
      #expect(try screen.shows("Needs a browser"))
      #expect(try screen.shows("Finish this in the browser"))
      #expect(try screen.shows("a.test"))
      // It's never opened on its own.
      #expect(log.openedURLs.isEmpty)
      try screen.tapButton(0)
      #expect(log.openedURLs == [URL(string: "https://a.test/ok")])
      #expect(log.responses.isEmpty)
    }

    @Test("An address that isn't safe to open isn't offered, nor is one that's missing")
    func unsupportedUnsafe() throws {
      for address in ["javascript:alert(1)", nil] {
        let card = DecisionCard.sample(
          title: "Sign in", kind: .unsupported(reason: "No way here", externalUrl: address))
        let screen = open(card)
        defer { screen.close() }
        #expect(try screen.shows("No way here"))
        #expect(try !screen.shows("Open approval page"))
        #expect(screen.buttons.isEmpty)
      }
    }

    // MARK: Command-Return

    private func shortcutScreen(
      _ owner: String?, isLive: Bool = true, card: DecisionCard = .sample(detail: "Do it")
    ) -> OffscreenWindow<some View> {
      let root = DecisionCardScreen(card: card, model: DecisionCardModel(), log: log)
        .decisionApproveShortcut(owner, isLive: isLive)
      let screen = OffscreenWindow(root)
      screen.settle()
      return screen
    }

    private func pressCommandReturn(_ screen: OffscreenWindow<some View>) throws -> Bool {
      try screen.pressShortcut(
        keyCode: ComposerKey.returnKey, characters: "\r", modifiers: .command)
    }

    @Test("Command-Return approves the one card that owns it, and the button shows it")
    func shortcut() throws {
      let screen = shortcutScreen("card")
      defer { screen.close() }
      #expect(try screen.shows("\u{2318}\u{21A9}"))
      #expect(try pressCommandReturn(screen))
      #expect(log.responses == [.approve])
    }

    @Test("Command-Return does nothing on another card, or while the shortcut isn't live")
    func shortcutElsewhere() throws {
      for (owner, isLive) in [("other", true), ("card", false), (nil, true)] {
        let screen = shortcutScreen(owner, isLive: isLive)
        defer { screen.close() }
        #expect(try !screen.shows("\u{2318}\u{21A9}"))
        _ = try pressCommandReturn(screen)
        #expect(log.responses.isEmpty)
      }
    }

    @Test("While a reply is open Command-Return no longer approves")
    func shortcutWhileReplying() throws {
      let screen = shortcutScreen("card", card: .sample(detail: "Do it", acceptsFeedback: true))
      defer { screen.close() }
      try screen.tapButton(2)
      #expect(try !screen.shows("\u{2318}\u{21A9}"))
      _ = try pressCommandReturn(screen)
      #expect(log.responses.isEmpty)
    }
  }
#endif
