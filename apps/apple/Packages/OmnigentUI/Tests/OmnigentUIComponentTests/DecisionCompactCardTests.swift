#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The one-line card and the full-screen review a phone gets for a large request.
  @Suite("Decision card: compact row and review", .serialized)
  @MainActor
  struct DecisionCompactCardTests {
    private let log = DecisionResponseLog()

    private func compact(
      _ card: DecisionCard, model: DecisionCardModel = DecisionCardModel(), context: String? = nil
    ) -> OffscreenWindow<DecisionCardScreen> {
      let screen = OffscreenWindow(
        DecisionCardScreen(card: card, model: model, log: log, style: .compact, context: context))
      screen.settle()
      return screen
    }

    @Test("A short command answers from the row: Reject, then Approve")
    func inlineApproval() throws {
      let screen = compact(.command(), context: "Codex")
      defer { screen.close() }
      #expect(try screen.shows("Run cargo test"))
      #expect(try screen.shows("Codex"))
      // The row's own button, then Reject and Approve.
      #expect(screen.buttons.count == 3)
      try screen.tapButton(1)
      try screen.tapButton(2)
      #expect(log.responses == [.decline, .approve])
    }

    @Test("A short question answers from the row")
    func inlineChoice() throws {
      let card = DecisionCard.sample(
        title: "Response requested", detail: "Which?",
        kind: .choice(answerKey: "pick", options: ["One", "Two"]))
      let screen = compact(card)
      defer { screen.close() }
      try screen.tapButton(1)
      try screen.tapButton(2)
      #expect(log.responses == [.answer(value: "One"), .answer(value: "Two")])
    }

    @Test("A form or a long request opens with Review, then collapses back")
    func reviewAndCollapse() throws {
      let cards: [DecisionCard] = [
        .sample(kind: .form(fields: [FormField(key: "a", title: "Name", kind: .text)])),
        .command("cargo test\ncargo build"),
        .sample(
          title: "Sign in", kind: .unsupported(reason: "In the browser", externalUrl: nil)),
      ]
      for card in cards {
        let screen = compact(card)
        defer { screen.close() }
        #expect(try screen.shows("Review"))
        #expect(screen.buttons.count == 2)
        try screen.tapButton(1)
        #expect(try !screen.shownText().contains("Review"))
        // The header's Collapse comes first in the expanded card.
        try screen.tapButton(0)
        #expect(try screen.shows("Review"))
      }
    }

    @Test("Clicking the row's text opens the full card, whose answers work")
    func openFromRow() throws {
      let screen = compact(.command())
      defer { screen.close() }
      try screen.tapButton(0)
      #expect(try screen.shows("Command approval"))
      #expect(try screen.shows("$ cargo test"))
    }

    @Test("A row shows the phase in place of its actions")
    func rowPhases() throws {
      let resolving = compact(.command(), model: DecisionCardModel(phase: .resolving))
      defer { resolving.close() }
      #expect(resolving.buttons.count == 1)

      let answered = compact(
        .command(), model: DecisionCardModel(phase: .answered(summary: "Done")))
      defer { answered.close() }
      #expect(try answered.shows("Done"))
      #expect(answered.buttons.count == 1)

      let failed = compact(
        .command(), model: DecisionCardModel(phase: .failed(message: "No route")))
      defer { failed.close() }
      #expect(try failed.shows("No route"))
      #expect(failed.buttons.count == 3)
    }

    @Test("Read-only rows can open but not answer")
    func rowReadOnly() throws {
      let screen = compact(.command(), model: DecisionCardModel(isReadOnly: true))
      defer { screen.close() }
      #expect(screen.buttons.count == 1)
      try screen.tapButton(0)
      #expect(try screen.shows("Read-only access cannot respond to this request."))
    }

    @Test("Expanding an answered row shows its answered line")
    func answeredExpanded() throws {
      let screen = compact(.command(), model: DecisionCardModel(phase: .answered(summary: "Done")))
      defer { screen.close() }
      try screen.tapButton(0)
      #expect(try screen.shows("Waiting for the server"))
    }

    // MARK: Review, on a phone

    private func phone(
      _ card: DecisionCard, model: DecisionCardModel = DecisionCardModel()
    ) -> OffscreenWindow<DecisionCardScreen> {
      let screen = OffscreenWindow(
        DecisionCardScreen(card: card, model: model, log: log, layoutWidth: .compact))
      screen.settle()
      return screen
    }

    private var longInput: String { (1...10).map { "line \($0)" }.joined(separator: "\n") }

    private var largeCard: DecisionCard {
      .sample(detail: "Do it", message: "Do it", toolInput: longInput)
    }

    @Test("A small request has no review; a large one does")
    func reviewOffered() throws {
      let small = phone(.command())
      defer { small.close() }
      #expect(try !small.shows("Review full screen"))
      // Compact width folds the input and offers the review.
      let large = phone(largeCard)
      defer { large.close() }
      #expect(try large.shows("Show all \u{00B7} 4 more lines"))
      #expect(try !large.shows("line 7"))
    }

    @Test("The review unfolds the payload, can be closed, and switches wrapping")
    func reviewScreen() throws {
      let closes = Counter()
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: DecisionReviewScreen(
            card: largeCard, phase: .pending, isReadOnly: false, context: nil, respond: log.respond,
            validate: nil, draft: .constant(FormDraft()), close: { closes.count += 1 }
          ).frame(minWidth: 480, minHeight: 560)
        ))
      defer { screen.close() }
      screen.settle(0.5)
      #expect(try screen.shows("line 10"))
      #expect(try !screen.shows("Show all"))
      #expect(try screen.shows("Approve"))
      // A sheet's toolbar is along its bottom: Done, then the wrap switch.
      #expect(try screen.shows("Scroll long lines"))
      try screen.tapButton(fromEnd: 0)
      #expect(try screen.shows("Wrap long lines"))
      #expect(try screen.shows("line 10"))
      try screen.tapButton(fromEnd: 0)
      #expect(try screen.shows("Scroll long lines"))
      try screen.tapButton(fromEnd: 1)
      #expect(closes.count == 1)
    }

    @Test("The card's button opens the review sheet; answering there closes it")
    func reviewFromCard() throws {
      let screen = phone(largeCard)
      defer { screen.close() }
      // The button is the header's first control.
      try screen.tapButton(0)
      screen.settle(0.5)
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("line 10"))
      let approve = try #require(screen.buttons.first { $0.minY > 60 })
      try screen.click(screen.clickPoint(approve))
      screen.settle(0.5)
      #expect(log.responses == [.approve])
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("Done closes the review without answering")
    func reviewDone() throws {
      let screen = phone(largeCard)
      defer { screen.close() }
      try screen.tapButton(0)
      screen.settle(0.5)
      #expect(try screen.shows("Done"))
      try screen.tapButton(fromEnd: 1)
      screen.settle(0.5)
      #expect(screen.window.attachedSheet == nil)
      #expect(log.responses.isEmpty)
    }

    @MainActor
    private final class Counter {
      var count = 0
    }
  }
#endif
