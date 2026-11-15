#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor @Observable
  private final class ApproveModel {
    var showsApprove = true
  }

  private struct ReportingCard: View {
    let model: ApproveModel
    let surfaces: DecisionSurfaces

    var body: some View {
      ScrollView {
        Color.clear.frame(height: 200)
          .reportsInlineDecision("one", showsApprove: model.showsApprove)
      }
      .environment(surfaces)
      .frame(width: 400, height: 300)
    }
  }

  /// What a conversation's form validator was asked, and what its cards sent.
  @MainActor
  private final class FormValidationLog {
    var askedCards: [String] = []
    var lastValues: [String: ElicitationValue] = [:]
    var responses: [DecisionResponse] = []

    /// A conversation that takes only the name Ada.
    var actions: ConversationActions {
      var actions = ConversationActions()
      actions.respond = { [self] _, response in responses.append(response) }
      actions.validateForm = { [self] card, values in
        askedCards.append(card.id)
        lastValues = values
        return values["name"] == .text(value: "Ada")
          ? nil : DecisionFormProblem(message: "Must be Ada", fieldKey: "name")
      }
      return actions
    }

    static let card = DecisionCard.sample(
      id: "form",
      kind: .form(fields: [FormField(key: "name", title: "Name", kind: .text, required: false)]))
  }

  @Suite("Decisions: small gaps", .serialized)
  @MainActor
  struct DecisionsGapsTests {
    @Test("An inline card that stops offering Approve tells the dock so")
    func approveChanges() {
      let model = ApproveModel()
      let surfaces = DecisionSurfaces()
      let screen = OffscreenWindow(ReportingCard(model: model, surfaces: surfaces))
      defer { screen.close() }
      screen.settle()
      #expect(surfaces.visibility.approvable == ["one"])
      model.showsApprove = false
      screen.settle()
      #expect(surfaces.visibility.approvable.isEmpty)
      #expect(surfaces.visibility.onScreen == ["one"])
    }

    @Test("A long edit's diff folds on a card, and a click on Show all unfolds it to its last line")
    func diffShowAll() throws {
      let added = (1...20).map { "added \($0)" }.joined(separator: "\\n")
      let input =
        #"Edit({"file_path": "/a.swift", "old_string": "one", "new_string": ""#
        + added + #""})"#
      let screen = OffscreenWindow(
        DecisionCardScreen(
          card: .sample(message: "Edit", toolInput: input), model: DecisionCardModel(),
          log: DecisionResponseLog()))
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("added 1"))
      #expect(try screen.shows("Show all \u{00B7} "))
      #expect(try !screen.shows("added 20"))
      let showAll = try screen.withAccessibilityTree {
        try screen.accessibilityFrame("preview-show-all")
      }
      try screen.click(CGPoint(x: showAll.midX, y: showAll.midY))
      #expect(try screen.shows("added 20"))
      #expect(try !screen.shows("Show all"))
    }

    @Test("Inline Markdown applies, and text it can't parse shows as written")
    func inlineMarkdown() {
      let styled = InlineMarkdownText.attributed("use **Bash** now")
      #expect(String(styled.characters) == "use Bash now")
      struct Unparseable: Error {}
      let plain = InlineMarkdownText.attributed("use **Bash** now") { _ in throw Unparseable() }
      #expect(String(plain.characters) == "use **Bash** now")
    }

    /// Submit is off while the validator objects; once the name passes it is the last button
    /// but one, and sends the answers.
    private func answerAda<Content: View>(
      _ screen: OffscreenWindow<Content>, log: FormValidationLog
    ) throws {
      #expect(try screen.shows("Must be Ada"))
      let blocked = screen.buttons.count
      try screen.type("Ada", intoField: 0)
      screen.settle(0.05)
      #expect(try !screen.shows("Must be Ada"))
      #expect(screen.buttons.count == blocked + 1, "Submit can be pressed now")
      try screen.tapButton(fromEnd: 1)
      #expect(log.responses == [.form(values: ["name": .text(value: "Ada")])])
      #expect(log.askedCards.allSatisfy { $0 == "form" } && !log.askedCards.isEmpty)
      #expect(log.lastValues == ["name": .text(value: "Ada")])
    }

    @Test("An inline form asks the conversation's validator, and Submit waits until it passes")
    func inlineFormValidator() throws {
      let log = FormValidationLog()
      let screen = OffscreenWindow(
        ScrollView {
          InlineDecisions(state: .requests([FormValidationLog.card]), actions: log.actions)
        }
        .frame(width: 800, height: 600))
      defer { screen.close() }
      screen.settle()
      try answerAda(screen, log: log)
    }

    @Test("The dock's form asks the same validator before it lets Submit through")
    func dockFormValidator() throws {
      let log = FormValidationLog()
      let screen = OffscreenWindow(
        DecisionDockScreen(
          host: DecisionDockModelHost(.requests([FormValidationLog.card])),
          actions: log.actions, startsExpanded: true))
      defer { screen.close() }
      screen.settle()
      try answerAda(screen, log: log)
    }
  }
#endif
