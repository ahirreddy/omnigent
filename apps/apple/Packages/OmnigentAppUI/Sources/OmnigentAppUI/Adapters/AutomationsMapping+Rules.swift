import OmnigentCoreFFI
import OmnigentUIComponents

/// RRULE text: what an edit saves and the editor's Visual | RRULE switch.
extension AutomationsMapping {
  /// The rule to save for `schedule`: an edited automation's stored spelling while the schedule
  /// reads the same, as the web's, so its pending run isn't rescheduled.
  static func rule(_ schedule: ScheduleChoice, saved: Automation?) -> String {
    let built = buildScheduleRrule(model: model(schedule))
    guard let saved, storedRule(saved) == built else { return built }
    return saved.rrule
  }

  /// A saved rule as the editor rebuilds it, or `nil` when the editor can't read it.
  static func storedRule(_ saved: Automation) -> String? {
    parseScheduleRrule(rrule: saved.rrule).map { buildScheduleRrule(model: $0) }
  }

  /// The Visual | RRULE switch's conversions, from the core.
  static let ruleConversion = ScheduleRuleConversion(
    text: { recurringScheduleRrule(model: model($0)) },
    visual: { text in
      parseScheduleRrule(rrule: normalizeScheduleRule(rule: text))
        .flatMap { $0.frequency == .rule ? nil : choice($0) }
    },
    summary: { text in
      let rule = normalizeScheduleRule(rule: text)
      let summary = describeSchedule(rrule: rule)
      return summary == rule ? nil : summary
    })
}
