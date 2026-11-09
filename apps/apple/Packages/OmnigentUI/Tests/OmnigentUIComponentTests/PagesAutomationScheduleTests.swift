#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The schedule fields in the Form they live in, showing what the controls wrote back.
  private struct ScheduleHost: View {
    let choice: EditedValue<ScheduleChoice>
    var anchored = true

    var body: some View {
      Form { ScheduleFields(choice: choice.binding, anchoredScheduling: anchored) }
        .formStyle(.grouped)
    }
  }

  @Suite("Schedule fields, clicked", .serialized)
  @MainActor
  struct PagesAutomationScheduleTests {
    private func screen(
      _ choice: EditedValue<ScheduleChoice>, anchored: Bool = true
    ) -> OffscreenWindow<ScheduleHost> {
      SystemSideEffects.reset()
      return OffscreenWindow(
        ScheduleHost(choice: choice, anchored: anchored), width: 700, height: 700)
    }

    private func custom(_ frequency: ScheduleChoice.Frequency) -> EditedValue<ScheduleChoice> {
      EditedValue(ScheduleChoice(preset: .custom, frequency: frequency))
    }

    @Test("typing several days of the month keeps them all")
    func typedMonthDays() throws {
      let choice = custom(.monthly)
      let screen = screen(choice)
      defer { screen.close() }
      let field = try #require(screen.fields.first)
      try screen.replaceText(in: field, with: "1, 15")
      #expect(choice.value.monthDays == [1, 15])
    }

    @Test("the preset picker switches the schedule and shows that preset's fields")
    func presets() throws {
      let choice = EditedValue(ScheduleChoice())
      let screen = screen(choice)
      defer { screen.close() }
      let preset = try #require(screen.popUps.first)
      #expect(preset.title == "Every day")
      #expect(try screen.titles(inPopUp: preset).contains("Custom schedule"))
      try screen.choose("Every week", inPopUp: preset)
      #expect(choice.value.preset == .weekly)
      #expect(try screen.shows("Mon"))
      try screen.choose("Every hour", inPopUp: try #require(screen.popUps.first))
      #expect(choice.value.preset == .hourly)
      #expect(try screen.shows("At minute"))
      #expect(try !screen.shows("Mon"))
    }

    @Test("clicking days adds and removes them, but never the last one")
    func weekdays() throws {
      let choice = EditedValue(ScheduleChoice(preset: .weekly, weekdays: [0]))
      let screen = screen(choice)
      defer { screen.close() }
      // Preset, then Monday to Sunday.
      try screen.clickControl(at: 2)
      #expect(choice.value.weekdays == [0, 1])
      try screen.clickControl(at: 1)
      #expect(choice.value.weekdays == [1])
      try screen.clickControl(at: 2)
      #expect(choice.value.weekdays == [1], "the only day stays")
    }

    @Test("a custom schedule's stepper changes the interval within its range")
    func interval() throws {
      let choice = custom(.daily)
      let screen = screen(choice)
      defer { screen.close() }
      let stepper = try #require(screen.allViews.compactMap { $0 as? NSStepper }.first)
      let frame = stepper.convert(stepper.bounds, to: screen.host)
      try screen.click(CGPoint(x: frame.midX, y: frame.minY + 3))
      #expect(choice.value.interval == 2)
      try screen.click(CGPoint(x: frame.midX, y: frame.maxY - 3))
      try screen.click(CGPoint(x: frame.midX, y: frame.maxY - 3))
      #expect(choice.value.interval == 1, "never below 1")
    }

    @Test("the custom unit decides the fields, and a yearly schedule picks its month")
    func customUnit() throws {
      let choice = custom(.daily)
      let screen = screen(choice)
      defer { screen.close() }
      #expect(screen.fields.isEmpty)
      let unit = try #require(screen.popUps.first { $0.title == "Days" })
      try screen.choose("Years", inPopUp: unit)
      #expect(choice.value.frequency == .yearly)
      #expect(screen.fields.count == 1)
      let month = try #require(screen.popUps.first { $0.title == "January" })
      try screen.choose("March", inPopUp: month)
      #expect(choice.value.month == 3)
    }

    @Test("an hourly schedule picks its minute")
    func minute() throws {
      let choice = EditedValue(ScheduleChoice(preset: .hourly, minute: 5))
      let screen = screen(choice)
      defer { screen.close() }
      let minute = try #require(screen.popUps.first { $0.title == ":05" })
      try screen.choose(":30", inPopUp: minute)
      #expect(choice.value.minute == 30)
    }

    @Test("the time picker writes the hour and minute")
    func time() throws {
      let choice = EditedValue(ScheduleChoice(hour: 9, minute: 0))
      let screen = screen(choice)
      defer { screen.close() }
      let picker = try #require(screen.allViews.compactMap { $0 as? NSDatePicker }.first)
      var parts = Calendar.current.dateComponents([.year, .month, .day], from: picker.dateValue)
      parts.hour = 14
      parts.minute = 35
      picker.dateValue = try #require(Calendar.current.date(from: parts))
      _ = picker.sendAction(picker.action, to: picker.target)
      screen.settle()
      #expect(choice.value.hour == 14)
      #expect(choice.value.minute == 35)
    }

    @Test("the ending can be a date at the end of that day, or a run count from 2")
    func endings() throws {
      let choice = EditedValue(ScheduleChoice())
      let screen = screen(choice)
      defer { screen.close() }
      func ends() throws -> NSButton {
        try #require(screen.popUps.first { ["Never", "On date", "After"].contains($0.title) })
      }
      try screen.choose("On date", inPopUp: try ends())
      guard case .until(let date) = choice.value.end else {
        Issue.record("no end date: \(choice.value.end)")
        return
      }
      let time = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
      #expect([time.hour, time.minute, time.second] == [23, 59, 59])
      try screen.choose("After", inPopUp: try ends())
      #expect(choice.value.end == .count(2))
      #expect(try screen.shows("2 runs"))
      let stepper = try #require(screen.allViews.compactMap { $0 as? NSStepper }.last)
      let frame = stepper.convert(stepper.bounds, to: screen.host)
      try screen.click(CGPoint(x: frame.midX, y: frame.minY + 3))
      #expect(choice.value.end == .count(3))
      try screen.choose("Never", inPopUp: try ends())
      #expect(choice.value.end == .never)
    }

    @Test("a server without anchored scheduling doesn't offer run counts")
    func unanchored() throws {
      let choice = EditedValue(ScheduleChoice())
      let screen = screen(choice, anchored: false)
      defer { screen.close() }
      let ends = try #require(screen.popUps.first { $0.title == "Never" })
      #expect(try !screen.titles(inPopUp: ends).contains("After"))
    }

    @Test("a saved run count on such a server still shows, but can't be changed")
    func unanchoredKeptCount() throws {
      let choice = EditedValue(ScheduleChoice(end: .count(5)))
      let screen = screen(choice, anchored: false)
      defer { screen.close() }
      #expect(try screen.shows("5 runs"))
      let stepper = try #require(screen.allViews.compactMap { $0 as? NSStepper }.first)
      #expect(!stepper.isEnabled)
    }
  }
#endif
