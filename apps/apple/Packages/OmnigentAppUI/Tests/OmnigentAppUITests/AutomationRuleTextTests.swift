import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// RRULE text in the schedule editor, as the web's Visual | RRULE switch keeps it.
@MainActor
@Suite("Automations mapping: RRULE text")
struct AutomationRuleTextTests {
  private func automation(rrule: String) -> Automation {
    Automation(
      id: "t1", name: "Standup", prompt: "Summarize", rrule: rrule,
      scheduleText: describeSchedule(rrule: rrule), agentId: "a1", timezone: "Europe/Paris",
      continuesSession: true, state: .active, nextRunAt: nil, lastRunAt: nil,
      lastRunStatus: nil, lastRunSessionId: nil, updatedAt: 0)
  }

  @Test(
    "A rule the visual controls can't show opens as RRULE text and saves back as stored")
  func ruleText() throws {
    let stored = "rrule:freq=weekly;byday=mo,tu,we,th,fr;byhour=9,17;byminute=0;count=4"
    let saved = automation(rrule: stored)
    let draft = AutomationsMapping.draft(saved)
    let schedule = try #require(draft.schedule)
    #expect(schedule.isRule)
    #expect(schedule.rule == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9,17;BYMINUTE=0")
    #expect(schedule.end == .count(4))
    #expect(draft.keptRule == nil)
    let request = { (draft: AutomationDraftState) in
      AutomationsMapping.request(
        draft, prompt: "", saved: saved, sessionModes: false, sendsOverrides: false
      ).rrule
    }
    #expect(request(draft) == stored, "an untouched schedule keeps its stored spelling")
    var edited = draft
    edited.schedule?.rule = "FREQ=DAILY;BYHOUR=9,17;BYMINUTE=0"
    #expect(request(edited) == "FREQ=DAILY;BYHOUR=9,17;BYMINUTE=0;COUNT=4")
    let now = Date(timeIntervalSince1970: 1_793_865_600)
    #expect(
      AutomationsMapping.scheduleProblem(schedule, saved: saved, anchored: true, now: now) == nil)
    edited.schedule?.rule = "FREQ=DAILY;COUNT=2"
    #expect(
      AutomationsMapping.scheduleProblem(edited.schedule, saved: saved, anchored: true, now: now)
        == "Set when the schedule ends under Ends instead of with COUNT or UNTIL.")
  }

  @Test("The Visual | RRULE switch's conversions are the core's")
  func conversions() {
    let conversion = AutomationsMapping.ruleConversion
    #expect(
      conversion.text(ScheduleChoice(preset: .weekdays))
        == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0")
    #expect(conversion.visual(" rrule:freq=daily;byhour=8;byminute=15 ")?.preset == .daily)
    #expect(conversion.visual("FREQ=DAILY;BYHOUR=8,9;BYMINUTE=0") == nil)
    #expect(conversion.summary("FREQ=DAILY;BYHOUR=8;BYMINUTE=0") == "Every day at 8:00 AM")
    #expect(conversion.summary("FREQ=DAILY;BYHOUR=8,9;BYMINUTE=0") == nil)
  }
}
