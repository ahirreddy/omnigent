#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The typed form card: every kind of field, its problems, and what Submit sends.
  @Suite("Decision card: forms", .serialized)
  @MainActor
  struct DecisionFormCardTests {
    private let log = DecisionResponseLog()

    private func open(
      _ fields: [FormField], title: String = "Response requested", detail: String = "",
      model: DecisionCardModel = DecisionCardModel()
    ) -> OffscreenWindow<DecisionCardScreen> {
      let card = DecisionCard.sample(title: title, detail: detail, kind: .form(fields: fields))
      let screen = OffscreenWindow(DecisionCardScreen(card: card, model: model, log: log))
      screen.settle()
      return screen
    }

    /// Submit is the last button but one, when it's enabled at all.
    private func submit(_ screen: OffscreenWindow<DecisionCardScreen>) throws {
      try screen.tapButton(fromEnd: 1)
    }

    private func cancelIsLast(_ screen: OffscreenWindow<DecisionCardScreen>) throws {
      try screen.tapButton(fromEnd: 0)
      #expect(log.responses == [.cancel])
    }

    @Test("A title, its detail, and whether a field is required")
    func headings() throws {
      let screen = open(
        [
          FormField(key: "name", title: "Name", detail: "Your full name", kind: .text),
          FormField(key: "nick", title: "Nickname", kind: .text, required: false),
        ], title: "About you", detail: "A few questions")
      defer { screen.close() }
      #expect(try screen.shows("About you"))
      #expect(try screen.shows("A few questions"))
      #expect(try screen.shows("Your full name"))
      #expect(try screen.shows("Required"))
      #expect(try screen.shows("Optional"))
    }

    @Test("A form with a generic title is headed Questions")
    func genericTitle() throws {
      let screen = open([FormField(key: "name", title: "Name", kind: .text)])
      defer { screen.close() }
      #expect(try screen.shows("Questions"))
    }

    @Test("Text is required before Submit, and sent as typed")
    func text() throws {
      let screen = open([FormField(key: "name", title: "Name", kind: .text)])
      defer { screen.close() }
      #expect(try screen.shows("Enter Name."))
      let empty = screen.buttons.count
      try screen.type("Ada", intoField: 0)
      screen.settle(0.05)
      #expect(try !screen.shows("Enter Name."))
      #expect(screen.buttons.count == empty + 1)
      try submit(screen)
      #expect(log.responses == [.form(values: ["name": .text(value: "Ada")])])
    }

    @Test("An optional field left empty isn't sent")
    func optionalEmpty() throws {
      let screen = open([FormField(key: "name", title: "Name", kind: .text, required: false)])
      defer { screen.close() }
      try submit(screen)
      #expect(log.responses == [.form(values: [:])])
    }

    @Test("Cancel dismisses the form, even with answers missing")
    func cancel() throws {
      let screen = open([FormField(key: "name", title: "Name", kind: .text)])
      defer { screen.close() }
      try cancelIsLast(screen)
    }

    @Test("A text limit counts characters as they're typed")
    func maxLength() throws {
      let screen = open([FormField(key: "name", title: "Name", kind: .text, maxLength: 3)])
      defer { screen.close() }
      #expect(try screen.shows("0 of 3 characters"))
      try screen.type("Adam", intoField: 0)
      screen.settle(0.05)
      #expect(try screen.shows("4 of 3 characters"))
    }

    @Test("A secret field hides what's typed and still sends it")
    func secret() throws {
      let screen = open([FormField(key: "token", title: "Token", kind: .text, isSecret: true)])
      defer { screen.close() }
      #expect(screen.allViews.contains { $0 is NSSecureTextField })
      try screen.type("hunter2", intoField: 0)
      screen.settle(0.05)
      #expect(try !screen.shows("hunter2"))
      try submit(screen)
      #expect(log.responses == [.form(values: ["token": .text(value: "hunter2")])])
    }

    @Test("A whole number must be one")
    func integer() throws {
      let screen = open([FormField(key: "count", title: "Count", kind: .integer)])
      defer { screen.close() }
      #expect(try screen.shows("Whole number"))
      #expect(try screen.shows("Enter Count."))
      try screen.type("1.5", intoField: 0)
      screen.settle(0.05)
      #expect(try screen.shows("Count must be a whole number."))
      #expect(screen.buttons.count == 2)
      try screen.type("", intoField: 0)
      screen.fields[0].stringValue = ""
      screen.fields[0].currentEditor()?.string = ""
      screen.fields[0].currentEditor()?.selectAll(nil)
      try screen.type("42", intoField: 0)
      screen.settle(0.05)
      #expect(try !screen.shows("Count must be a whole number."))
      try submit(screen)
      #expect(log.responses == [.form(values: ["count": .integer(value: 42)])])
    }

    @Test("A number must be finite; an optional one left blank is fine")
    func number() throws {
      let screen = open([
        FormField(key: "ratio", title: "Ratio", kind: .number),
        FormField(key: "other", title: "Other", kind: .number, required: false),
      ])
      defer { screen.close() }
      #expect(try screen.shows("Number"))
      try screen.type("inf", intoField: 0)
      screen.settle(0.05)
      #expect(try screen.shows("Ratio must be a number."))
      screen.fields[0].currentEditor()?.selectAll(nil)
      try screen.type("0.5", intoField: 0)
      screen.settle(0.05)
      try submit(screen)
      #expect(log.responses == [.form(values: ["ratio": .number(value: 0.5)])])
    }

    @Test("A yes-or-no field starts unanswered and sends the side chosen")
    func boolean() throws {
      let screen = open([FormField(key: "ok", title: "Proceed", kind: .boolean)])
      defer { screen.close() }
      #expect(try screen.shows("Choose Yes or No for Proceed."))
      let segments = try #require(
        screen.allViews.lazy.compactMap { $0 as? NSSegmentedControl }.first)
      #expect(segments.selectedSegment == -1)
      #expect(segments.segmentCount == 2)
      let frame = segments.convert(segments.bounds, to: screen.activeWindow.contentView)
      try screen.click(CGPoint(x: frame.minX + frame.width * 0.75, y: frame.midY))
      #expect(try !screen.shows("Choose Yes or No for Proceed."))
      try submit(screen)
      try screen.click(CGPoint(x: frame.minX + frame.width * 0.25, y: frame.midY))
      try submit(screen)
      #expect(
        log.responses == [
          .form(values: ["ok": .bool(value: false)]), .form(values: ["ok": .bool(value: true)]),
        ])
    }

    private let options = [
      FormOption(value: "s", label: "Speed", detail: "Go fast"), FormOption(value: "m"),
    ]

    @Test("One choice replaces the last, and shows as selected")
    func singleChoice() throws {
      let field = FormField(key: "pick", title: "Pick", kind: .singleChoice, options: options)
      let screen = open([field])
      defer { screen.close() }
      #expect(try screen.shows("Choose an answer for Pick."))
      #expect(try screen.shows("Go fast"))
      try screen.tapButton(0)
      try screen.tapButton(1)
      #expect(try !screen.shows("Choose an answer for Pick."))
      try submit(screen)
      #expect(log.responses == [.form(values: ["pick": .text(value: "m")])])
    }

    @Test("Several choices toggle, and send in the order offered")
    func multipleChoice() throws {
      let field = FormField(key: "pick", title: "Pick", kind: .multipleChoice, options: options)
      let screen = open([field])
      defer { screen.close() }
      try screen.tapButton(1)
      try screen.tapButton(0)
      try submit(screen)
      try screen.tapButton(1)
      try submit(screen)
      #expect(
        log.responses == [
          .form(values: ["pick": .textList(values: ["s", "m"])]),
          .form(values: ["pick": .textList(values: ["s"])]),
        ])
    }

    @Test("Writing another answer replaces a single choice, and choosing clears what was written")
    func customSingle() throws {
      let field = FormField(
        key: "pick", title: "Pick", kind: .singleChoice, options: options, allowsCustom: true)
      let screen = open([field])
      defer { screen.close() }
      #expect(try screen.shows("Other answer"))
      try screen.tapButton(0)
      try screen.type("Mine", intoField: 0)
      screen.settle(0.05)
      try submit(screen)
      #expect(log.responses.last == .form(values: ["pick": .text(value: "Mine")]))
      try screen.tapButton(1)
      #expect(screen.fields.first?.stringValue.isEmpty == true)
      try submit(screen)
      #expect(log.responses.last == .form(values: ["pick": .text(value: "m")]))
    }

    @Test("Writing another answer adds to several choices")
    func customMultiple() throws {
      let field = FormField(
        key: "pick", title: "Pick", kind: .multipleChoice, options: options, allowsCustom: true)
      let screen = open([field])
      defer { screen.close() }
      try screen.tapButton(0)
      try screen.type("Mine", intoField: 0)
      screen.settle(0.05)
      try submit(screen)
      #expect(log.responses == [.form(values: ["pick": .textList(values: ["s", "Mine"])])])
    }

    // MARK: The core's validator

    @Test("A validator's problem with a field shows under it and blocks Submit")
    func validatorField() throws {
      log.validator = { _ in DecisionFormProblem(message: "Too short", fieldKey: "name") }
      let screen = open([FormField(key: "name", title: "Name", kind: .text, required: false)])
      defer { screen.close() }
      #expect(try screen.shows("Too short"))
      #expect(screen.buttons.count == 2)
    }

    @Test("A validator's problem naming no field stays by Submit and blocks it")
    func validatorGeneral() throws {
      log.validator = { _ in DecisionFormProblem(message: "The server said no") }
      let screen = open([FormField(key: "name", title: "Name", kind: .text, required: false)])
      defer { screen.close() }
      #expect(try screen.shows("The server said no"))
      #expect(screen.buttons.count == 2)
      try screen.tapButton(fromEnd: 0)
      #expect(log.responses == [.cancel])
    }

    @Test("The validator sees the answers, and clearing the problem frees Submit")
    func validatorSeesAnswers() throws {
      log.validator = { values in
        values["name"] == .text(value: "Ada")
          ? nil : DecisionFormProblem(message: "Must be Ada", fieldKey: "name")
      }
      let screen = open([FormField(key: "name", title: "Name", kind: .text, required: false)])
      defer { screen.close() }
      #expect(try screen.shows("Must be Ada"))
      try screen.type("Ada", intoField: 0)
      screen.settle(0.05)
      #expect(try !screen.shows("Must be Ada"))
      try submit(screen)
      #expect(log.responses == [.form(values: ["name": .text(value: "Ada")])])
    }

    @Test("A read-only form can't be filled in or sent")
    func readOnly() throws {
      let screen = open(
        [FormField(key: "name", title: "Name", kind: .text, required: false)],
        model: DecisionCardModel(isReadOnly: true))
      defer { screen.close() }
      #expect(try screen.shows("Read-only access cannot respond to this request."))
      #expect(screen.fields.isEmpty || screen.fields.allSatisfy { !$0.isEnabled })
    }
  }
#endif
