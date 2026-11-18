import Foundation
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI

  @testable import OmnigentUITestSupport
#endif

/// The defaults, hints and date text a form field works from: the MCP schema shapes Codex sends
/// (`default`, ranges, item counts, `format`).
@Suite("Decision form: defaults, hints and dates")
struct DecisionFormShapeLogicTests {
  private let fields = [
    FormField(key: "topic", title: "Topic", kind: .text, defaultValue: .text(value: "Weekly sync")),
    FormField(key: "count", title: "Guests", kind: .integer, defaultValue: .integer(value: 3)),
    FormField(key: "share", title: "Share", kind: .number, defaultValue: .number(value: 0.5)),
    FormField(key: "invite", title: "Invite", kind: .boolean, defaultValue: .bool(value: true)),
    FormField(
      key: "room", title: "Room", kind: .singleChoice,
      options: [FormOption(value: "north"), FormOption(value: "south")],
      defaultValue: .text(value: "south")),
    FormField(
      key: "who", title: "Attendees", kind: .multipleChoice, required: false,
      options: [FormOption(value: "ana"), FormOption(value: "bo")],
      defaultValue: .textList(values: ["ana"])),
  ]

  @Test("An untouched field answers with its default; an edit replaces it")
  func defaults() {
    var draft = FormDraft()
    #expect(draft.localProblem(for: fields) == nil)
    #expect(
      draft.values(for: fields) == [
        "topic": .text(value: "Weekly sync"), "count": .integer(value: 3),
        "share": .number(value: 0.5), "invite": .bool(value: true), "room": .text(value: "south"),
        "who": .textList(values: ["ana"]),
      ])
    #expect(draft.text(for: fields[1]) == "3")
    draft.text["topic"] = ""
    draft.booleans["invite"] = false
    draft.selected["who"] = []
    let edited = draft.values(for: fields)
    #expect(edited["topic"] == nil)
    #expect(edited["invite"] == .bool(value: false))
    #expect(edited["who"] == nil)
    #expect(draft.problem(for: fields[0]) == .missing("Enter Topic."))
  }

  @Test("Number bounds and choice counts read as hints")
  func hints() {
    let number = { (lowest: Double?, highest: Double?) in
      FormFieldHint.range(
        FormField(key: "n", title: "N", kind: .integer, minimum: lowest, maximum: highest))
    }
    #expect(number(1, 10) == "Between 1 and 10")
    #expect(number(1, nil) == "At least 1")
    #expect(number(nil, 2) == "At most 2")
    #expect(number(nil, nil) == nil)
    #expect(FormFieldHint.range(FormField(key: "t", title: "T", kind: .text, minimum: 1)) == nil)
    let count = { (fewest: UInt64?, most: UInt64?) in
      FormFieldHint.choices(
        FormField(key: "c", title: "C", kind: .multipleChoice, minItems: fewest, maxItems: most))
    }
    #expect(count(1, 2) == "Choose up to 2")
    #expect(count(2, 3) == "Choose 2 to 3")
    #expect(count(2, 2) == "Choose 2")
    #expect(count(2, nil) == "Choose at least 2")
    #expect(count(1, nil) == nil)
    #expect(FormFieldHint.placeholder(.email) == "name@example.com")
    #expect(FormFieldHint.placeholder(.date) == "YYYY-MM-DD")
  }

  @Test("An editor sends its exact text, empty included, as Pi's editor takes it")
  func editorExactText() {
    let editor = FormField(
      key: "0", title: "Edit the notes", kind: .text, exactText: true,
      defaultValue: .text(value: "Fixes\n"))
    let text = FormField(key: "name", title: "Name", kind: .text)
    var draft = FormDraft()
    #expect(draft.values(for: [editor]) == ["0": .text(value: "Fixes\n")])
    draft.text["0"] = ""
    draft.text["name"] = ""
    #expect(draft.values(for: [editor, text]) == ["0": .text(value: "")])
    #expect(draft.problem(for: editor) == nil)
    #expect(draft.problem(for: text) == .missing("Enter Name."))
    draft.text["0"] = "  kept\n"
    #expect(draft.values(for: [editor]) == ["0": .text(value: "  kept\n")])
  }

  @Test("Dates are written in the formats the core accepts and read back")
  func dates() {
    let instant = Date(timeIntervalSince1970: 1_763_400_000)
    let day = FormDateText.string(from: instant, format: .date)
    #expect(day.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil)
    let stamp = FormDateText.string(from: instant, format: .dateTime)
    #expect(stamp.wholeMatch(of: #/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})/#) != nil)
    #expect(FormDateText.date(from: stamp, format: .dateTime) == instant)
    #expect(FormDateText.date(from: day, format: .date) != nil)
    #expect(FormDateText.date(from: "tomorrow", format: .date) == nil)
  }

  private let layout = FormField(
    key: "layout", title: "Layout", kind: .singleChoice,
    options: [
      FormOption(value: "Plain"), FormOption(value: "Sidebar", preview: "[nav] | [body]"),
      FormOption(value: "Top bar", preview: "[nav]\n[body]"),
    ], allowsCustom: true, acceptsNotes: true)

  @Test("A note is sent with the answers only on a question that takes one, trimmed")
  func notes() {
    let platforms = FormField(
      key: "platforms", title: "Platforms", kind: .multipleChoice,
      options: [FormOption(value: "Mac"), FormOption(value: "iPhone")])
    var draft = FormDraft()
    draft.selected = ["layout": ["Top bar"], "platforms": ["Mac"]]
    let values: [String: ElicitationValue] = [
      "layout": .text(value: "Top bar"), "platforms": .textList(values: ["Mac"]),
    ]
    #expect(draft.response(for: [layout, platforms]) == .form(values: values))
    draft.notes = ["layout": "  Keep it light. ", "platforms": "Not a question that takes one"]
    #expect(
      draft.response(for: [layout, platforms])
        == .formWithNotes(values: values, notes: ["layout": "Keep it light."]))
    draft.notes["layout"] = " "
    #expect(draft.response(for: [layout, platforms]) == .form(values: values))
  }

  @Test("A choice previews its first option with one, then the chosen option's, never a typed one")
  func previews() {
    var draft = FormDraft()
    #expect(draft.previewedOption(for: layout)?.value == "Sidebar")
    draft.selected["layout"] = ["Top bar"]
    #expect(draft.previewedOption(for: layout)?.value == "Top bar")
    draft.selected["layout"] = ["Plain"]
    #expect(draft.previewedOption(for: layout) == nil)
    draft.selected["layout"] = []
    draft.custom["layout"] = "Tabs"
    #expect(draft.previewedOption(for: layout) == nil)
    #expect(!FormField(key: "k", title: "K", kind: .singleChoice).hasPreviews)
    #expect(layout.hasPreviews)
  }

  @Test("Approving a plan into a mode that still asks changes nothing standing")
  func planModeRoutes() {
    #expect(!DecisionResponse.approvePlanMode(mode: .default).changesStandingPermissions)
    #expect(DecisionResponse.approvePlanMode(mode: .auto).changesStandingPermissions)
    #expect(DecisionResponse.approveSuggestions.changesStandingPermissions)
    #expect(DecisionResponse.formWithNotes(values: [:], notes: [:]).summary == "Answers submitted")
  }
}

#if os(macOS)
  /// The form card for each MCP field shape Codex sends, and the page card for URL mode.
  @Suite("Decision card: MCP shapes", .serialized)
  @MainActor
  struct DecisionFormShapeCardTests {
    private let log = DecisionResponseLog()

    private func open(_ card: DecisionCard) -> OffscreenWindow<DecisionCardScreen> {
      let screen = OffscreenWindow(
        DecisionCardScreen(card: card, model: DecisionCardModel(), log: log))
      screen.settle()
      return screen
    }

    private func form(_ fields: [FormField]) -> DecisionCard {
      .sample(title: "Response requested", kind: .form(fields: fields))
    }

    @Test("Defaults show in their fields and are sent unless changed")
    func defaultsSent() throws {
      let screen = open(
        form([
          FormField(
            key: "topic", title: "Topic", kind: .text, defaultValue: .text(value: "Weekly sync")),
          FormField(
            key: "count", title: "Guests", kind: .integer, minimum: 1, maximum: 10,
            defaultValue: .integer(value: 3)),
          FormField(
            key: "room", title: "Room", kind: .singleChoice,
            options: [
              FormOption(value: "north", label: "North room"),
              FormOption(value: "south", label: "South room"),
            ], defaultValue: .text(value: "south")),
        ]))
      defer { screen.close() }
      #expect(screen.fields.map(\.stringValue) == ["Weekly sync", "3"])
      #expect(try screen.shows("Between 1 and 10"))
      #expect(try screen.shows("South room"))
      try screen.tapButton(fromEnd: 1)
      #expect(
        log.responses == [
          .form(values: [
            "topic": .text(value: "Weekly sync"), "count": .integer(value: 3),
            "room": .text(value: "south"),
          ])
        ])
    }

    @Test("A formatted field names its format and sends what was typed")
    func formatted() throws {
      let screen = open(
        form([
          FormField(key: "email", title: "Approver", kind: .text, format: .email),
          FormField(
            key: "who", title: "Attendees", kind: .multipleChoice, required: false,
            options: [FormOption(value: "ana"), FormOption(value: "bo"), FormOption(value: "cy")],
            maxItems: 2),
        ]))
      defer { screen.close() }
      #expect(try screen.shows("name@example.com"))
      #expect(try screen.shows("Choose up to 2"))
      try screen.type("lead@example.com", intoField: 0)
      screen.settle(0.05)
      try screen.tapButton(fromEnd: 1)
      #expect(log.responses == [.form(values: ["email": .text(value: "lead@example.com")])])
    }

    @Test("A date field offers Today, then a picker, and sends the date as text")
    func date() throws {
      let screen = open(form([FormField(key: "day", title: "Day", kind: .text, format: .date)]))
      defer { screen.close() }
      #expect(try screen.shows("Today"))
      #expect(!screen.allViews.contains { $0 is NSDatePicker })
      // The field, then Today; Submit is not offered until the day is set.
      try screen.tapButton(1)
      screen.settle(0.05)
      let today = FormDateText.string(from: Date(), format: .date)
      #expect(screen.fields.first?.stringValue == today)
      #expect(screen.allViews.contains { $0 is NSDatePicker })
      try screen.tapButton(fromEnd: 1)
      #expect(log.responses == [.form(values: ["day": .text(value: today)])])
    }

    @Test("A secret question's typed answer is masked and still sent")
    func secretOther() throws {
      let screen = open(
        form([
          FormField(
            key: "token", title: "Token", kind: .singleChoice,
            options: [FormOption(value: "Use the saved one")], allowsCustom: true, isSecret: true)
        ]))
      defer { screen.close() }
      #expect(screen.allViews.contains { $0 is NSSecureTextField })
      try screen.type("hunter2", intoField: 0)
      screen.settle(0.05)
      #expect(try !screen.shows("hunter2"))
      try screen.tapButton(fromEnd: 1)
      #expect(log.responses == [.form(values: ["token": .text(value: "hunter2")])])
    }

    @Test("A question shows the chosen option's preview and sends a note with the answer")
    func previewAndNote() throws {
      let question = "Which layout should the settings screen use?"
      let screen = open(
        form([
          FormField(
            key: question, title: question, detail: "Layout", kind: .singleChoice,
            options: [
              FormOption(
                value: "Sidebar", detail: "Sections on the left.", preview: "[nav] | [body]"),
              FormOption(value: "Top bar", detail: "Sections as tabs.", preview: "[nav] / [body]"),
            ], allowsCustom: true, acceptsNotes: true)
        ]))
      defer { screen.close() }
      #expect(try screen.shows("Sections on the left."))
      #expect(try screen.shows("Preview: Sidebar"))
      #expect(try screen.shows("[nav] | [body]"))
      try screen.tapButton(1)
      screen.settle(0.05)
      #expect(try screen.shows("Preview: Top bar"))
      #expect(try screen.shows("[nav] / [body]"))
      // The typed "Other" answer, then the note.
      try screen.type("Keep the tabs short.", intoField: 1)
      screen.settle(0.05)
      try screen.tapButton(fromEnd: 1)
      #expect(
        log.responses == [
          .formWithNotes(
            values: [question: .text(value: "Top bar")],
            notes: [question: "Keep the tabs short."])
        ])
    }

    @Test("A page opens only when asked; Done accepts and Decline declines")
    func externalPage() throws {
      for (button, response) in [(1, DecisionResponse.approve), (2, .decline)] {
        log.responses = []
        log.openedURLs = []
        let screen = open(
          .sample(
            title: "Action required", detail: "Review the payment details.",
            kind: .externalPage(url: "https://a.test/pay")))
        defer { screen.close() }
        #expect(try screen.shows("Action required"))
        #expect(try screen.shows("Finish this on its page, then choose Done."))
        #expect(try screen.shows("a.test"))
        #expect(log.openedURLs.isEmpty)
        try screen.tapButton(0)
        #expect(log.openedURLs == [URL(string: "https://a.test/pay")])
        #expect(log.responses.isEmpty)
        try screen.tapButton(button)
        #expect(log.responses == [response])
      }
    }
  }
#endif
