import SwiftUI

/// Visual or RRULE, as the web's pill tabs; RRULE needs anchored scheduling. As the web's
/// `changeEditor`, RRULE starts from the visual schedule's rule, and Visual reads the rule back
/// or returns to the schedule before it, keeping the ending either way.
struct ScheduleEditorPicker: View {
  @Binding var choice: ScheduleChoice
  let rules: ScheduleRuleConversion
  var anchoredScheduling = true
  /// The visual schedule to return to when the rule's text has no visual equivalent.
  @State private var visualBeforeRule: ScheduleChoice?

  var body: some View {
    Picker("Schedule editor", selection: selection) {
      Text("Visual").tag(false)
      Text("RRULE").tag(true)
        .selectionDisabled(!anchoredScheduling && !choice.isRule)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
    .accessibilityIdentifier("automation-schedule-editor")
  }

  private var selection: Binding<Bool> {
    Binding(
      get: { choice.isRule },
      set: { toRule in
        guard toRule != choice.isRule else { return }
        if toRule {
          visualBeforeRule = choice
          var next = choice
          next.rule = rules.text(choice)
          next.preset = .custom
          next.frequency = .rule
          choice = next
        } else {
          var next = rules.visual(choice.rule) ?? visualBeforeRule ?? ScheduleChoice()
          next.end = choice.end
          choice = next
        }
      })
  }
}

/// A schedule's RRULE text: one line, with what it reads as, or where its zone and ending are
/// set, as the web's RRULE tab.
struct ScheduleRuleFields: View {
  @Binding var choice: ScheduleChoice
  let rules: ScheduleRuleConversion?
  var anchoredScheduling = true

  /// A weekday business-hours rule, as the web's placeholder.
  static let example =
    "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9,10,11,12,13,14,15,16,17;BYMINUTE=0"

  /// Said under a rule without a plain-language summary, as the web's.
  static let hint = "RFC 5545 RRULE, run in the timezone below. Set the end under Ends."

  var body: some View {
    TextField("RRULE string", text: text, prompt: Text(Self.example), axis: .vertical)
      .font(.body.monospaced())
      .lineLimit(1...4)
      .autocorrectionDisabled()
      #if os(iOS)
        .textInputAutocapitalization(.characters)
      #endif
      .disabled(!anchoredScheduling)
      .accessibilityIdentifier("automation-schedule-rule")
    Text(rules?.summary(choice.rule) ?? Self.hint)
      .font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("automation-schedule-rule-summary")
  }

  /// The rule's text. A rule is one line, so Return adds no second one; pasted lines stay, and
  /// the check says why they can't be saved.
  private var text: Binding<String> {
    Binding(
      get: { choice.rule },
      set: { text in
        guard text.replacingOccurrences(of: "\n", with: "") != choice.rule else { return }
        choice.rule = text
      })
  }
}
