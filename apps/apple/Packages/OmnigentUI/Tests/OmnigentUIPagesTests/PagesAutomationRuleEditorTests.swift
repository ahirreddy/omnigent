#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The schedule picker's Visual | RRULE switch, clicked as the web's.
  @Suite("Automation editor: RRULE text", .serialized)
  @MainActor
  struct PagesAutomationRuleEditorTests {
    @Test("Visual and RRULE move a schedule between the controls and its rule, keeping its end")
    func ruleEditor() throws {
      var context = AutomationEditorContext(
        agents: [AutomationOption(id: "a1", name: "Claude Code")], supportsSessionModes: true,
        describe: { "Summary of \($0.preset.title)" })
      context.anchoredScheduling = true
      context.ruleConversion = ScheduleRuleConversion(
        text: { "FREQ=DAILY;BYHOUR=\($0.hour);BYMINUTE=0" },
        visual: { $0 == "FREQ=DAILY;BYHOUR=7;BYMINUTE=0" ? ScheduleChoice(hour: 7) : nil },
        summary: { $0.hasPrefix("FREQ=DAILY") ? "Daily, summarized" : nil })
      let draft = EditedValue(AutomationDraftState(schedule: ScheduleChoice(end: .count(3))))
      SystemSideEffects.reset()
      let screen = OffscreenWindow(
        AutomationEditorSheet(
          draft: draft.binding, context: context, save: {}, cancel: {}), width: 720,
        height: 1_500)
      defer { screen.close() }
      let editor = try #require(
        screen.segmentedControls.first { $0.label(forSegment: 0) == "Visual" })
      try screen.click(segment: 1, of: editor)
      #expect(draft.value.schedule?.isRule == true)
      #expect(draft.value.schedule?.rule == "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")
      #expect(try screen.shows("Daily, summarized"))

      let field = try #require(
        screen.textFields.first { $0.placeholderString == ScheduleRuleFields.example })
      try screen.replaceText(in: field, with: "FREQ=DAILY;BYHOUR=7;BYMINUTE=0")
      #expect(draft.value.schedule?.rule == "FREQ=DAILY;BYHOUR=7;BYMINUTE=0")
      try screen.click(segment: 0, of: editor)
      #expect(draft.value.schedule == ScheduleChoice(hour: 7, end: .count(3)))
    }
  }
#endif
