import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// Schedules: rules come from a server, and the editor's numbers are clamped into the core's.
@MainActor
@Suite("Automation schedules from hostile data")
struct AutomationScheduleHostileTests {
  private func automation(rrule: String, scheduleText: String = "") -> Automation {
    Automation(
      id: "t", name: "", prompt: "", rrule: rrule, scheduleText: scheduleText, agentId: "",
      timezone: "", continuesSession: false, state: .unknown(value: ""), nextRunAt: nil,
      lastRunAt: nil, lastRunStatus: nil, lastRunSessionId: nil, updatedAt: .min)
  }

  @Test(
    "A rule the editor can't read is kept as it came",
    arguments: [
      "", " ", "FREQ=", "FREQ=EXPLODED", "garbage;;;===", "FREQ=DAILY;BYHOUR=99;BYMINUTE=99",
      "FREQ=DAILY;INTERVAL=99999999999999999999", "FREQ=DAILY;COUNT=-1", "FREQ=WEEKLY;BYDAY=ZZ",
      "FREQ=DAILY;UNTIL=99999999T999999Z", "FREQ=DAILY;UNTIL=", "FREQ=MONTHLY;BYMONTHDAY=400",
      "FREQ=YEARLY;BYMONTH=0;BYMONTHDAY=0", "FREQ=DAILY;BYHOUR=-1;BYMINUTE=-1",
    ])
  func unreadableRules(rule: String) {
    let saved = automation(rrule: rule, scheduleText: "kept text")
    let draft = AutomationsMapping.draft(saved)
    if draft.schedule == nil {
      #expect(draft.keptRule == "kept text")
      let request = AutomationsMapping.request(
        draft, prompt: "", saved: saved, sessionModes: false, sendsOverrides: false)
      #expect(request.rrule == rule)
    } else {
      // One the core parses must describe and rebuild without trouble.
      #expect(!AutomationsMapping.describe(draft.schedule ?? ScheduleChoice()).isEmpty)
    }
  }

  @Test("A very long rule doesn't take the parser down")
  func longRule() {
    let rule = "FREQ=DAILY;" + String(repeating: "BYHOUR=1;", count: 200_000)
    let draft = AutomationsMapping.draft(automation(rrule: rule))
    #expect(draft.schedule != nil || draft.keptRule != nil)
    #expect(!describeSchedule(rrule: String(repeating: "\u{1F600}", count: 200_000)).isEmpty)
  }

  @Test("An until at the edges of what a rule can spell survives the round trip")
  func extremeUntilRules() throws {
    for rule in [
      "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;UNTIL=99991231T235959Z",
      "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;UNTIL=00010101T000000Z",
    ] {
      let draft = AutomationsMapping.draft(automation(rrule: rule))
      if let schedule = draft.schedule {
        #expect(buildScheduleRrule(model: AutomationsMapping.model(schedule)).hasPrefix("FREQ"))
      }
    }
  }

  @Test("The editor's numbers clamp into what a schedule can hold")
  func clampedChoices() {
    var choice = ScheduleChoice()
    choice.hour = .max
    choice.minute = .min
    choice.interval = .max
    choice.month = .min
    choice.monthDays = [.min, .max]
    choice.weekdays = [-1, 0, 6, 7, .max, .min]
    choice.end = .count(.max)
    let model = AutomationsMapping.model(choice)
    #expect(model.hour == .max)
    #expect(model.minute == 0)
    #expect(model.interval == .max)
    #expect(model.month == 0)
    #expect(model.monthDays == [0, .max])
    #expect(model.weekdays == [.monday, .sunday])
    #expect(model.end == .count(count: .max))
    choice.end = .count(.min)
    #expect(AutomationsMapping.model(choice).end == .count(count: 0))
    #expect(!buildScheduleRrule(model: AutomationsMapping.model(choice)).isEmpty)
    #expect(!AutomationsMapping.describe(choice).isEmpty)
  }

  @Test("Weekdays count from Monday; anything else isn't a day")
  func weekdayIndexes() {
    #expect(Weekday(index: 0) == .monday)
    #expect(Weekday(index: 6) == .sunday)
    #expect(Weekday(index: 7) == nil)
    #expect(Weekday(index: -1) == nil)
    #expect(Weekday.sunday.index == 6)
  }

  @Test("Choices and models convert both ways for every preset and frequency")
  func conversions() {
    for preset in ScheduleChoice.Preset.allCases {
      for frequency in ScheduleChoice.Frequency.allCases {
        var choice = ScheduleChoice()
        choice.preset = preset
        choice.frequency = frequency
        let round = AutomationsMapping.choice(AutomationsMapping.model(choice))
        #expect(round.preset == preset)
        #expect(round.frequency == frequency)
      }
    }
  }

  @Test("An until any 64-bit server value could name reads back as a date")
  func untilFromAModel() {
    let model = ScheduleModel(
      preset: .custom, hour: 0, minute: 0, weekdays: [], frequency: .daily, interval: 1,
      monthDays: [], month: 1, end: .until(at: .min))
    let choice = AutomationsMapping.choice(model)
    #expect(choice.end == .until(Date(timeIntervalSince1970: TimeInterval(Int64.min))))
    #expect(AutomationsMapping.choice(model).preset == .custom)
  }

  @Test("An until past Int64 saves as some date")
  func untilPastInt64() {
    var choice = ScheduleChoice()
    choice.end = .until(Date(timeIntervalSince1970: TimeInterval(Int64.max)))
    #expect(AutomationsMapping.model(choice).end != .never)
  }

  @Test("Next-run text reads at both ends of the 64-bit range")
  func nextRunText() {
    for nextRun in [Int64.min, -1, 0, .max] {
      for now in [Int64.min, 0, 1_700_000_000, .max] {
        #expect(!formatNextRun(nextRunAt: nextRun, now: now).isEmpty)
      }
    }
  }

  @Test("A schedule problem is reported, not raised, whatever the end and clock")
  func scheduleProblems() {
    #expect(
      AutomationsMapping.scheduleProblem(
        nil, saved: nil, anchored: false, now: .distantPast) == nil)
    var choice = ScheduleChoice()
    choice.preset = .custom
    #expect(
      AutomationsMapping.scheduleProblem(choice, saved: nil, anchored: false, now: .now)?
        .contains("does not support") == true)
    choice.preset = .daily
    choice.end = .until(.distantPast)
    let past = AutomationsMapping.scheduleProblem(choice, saved: nil, anchored: true, now: .now)
    #expect(past != nil)
    let rule = buildScheduleRrule(model: AutomationsMapping.model(choice))
    // The same past end is allowed on the automation that already has it.
    #expect(
      AutomationsMapping.scheduleProblem(
        choice, saved: automation(rrule: rule), anchored: true, now: .now) == nil)
    choice.end = .until(.distantFuture)
    #expect(
      AutomationsMapping.scheduleProblem(choice, saved: nil, anchored: true, now: .distantPast)
        == nil)
  }

  @Test("Saving trims optional fields away; a new rule beats nothing to keep")
  func requests() {
    var draft = AutomationDraftState()
    draft.hostID = " \n"
    draft.workspace = "  /src  "
    draft.projectID = ""
    draft.schedule = nil
    let request = AutomationsMapping.request(
      draft, prompt: "", saved: nil, sessionModes: true, sendsOverrides: false)
    #expect(request.rrule.isEmpty)
    #expect(request.hostId == nil)
    #expect(request.workspace == "/src")
    #expect(request.projectId == nil)
    #expect(request.continuesSession == false)
    #expect(request.timezone == TimeZone.current.identifier)
  }

  @Test("Overrides restore from the automation, or clear without one")
  func overrides() {
    var saved = automation(rrule: "")
    saved.modelOverride = "opus"
    saved.reasoningEffort = "high"
    saved.permissionMode = "plan"
    var draft = AutomationDraftState()
    AutomationsMapping.restoreOverrides(&draft, from: saved)
    #expect(draft.model == "opus")
    #expect(draft.effort == "high")
    #expect(draft.permissionMode == "plan")
    AutomationsMapping.restoreOverrides(&draft, from: nil)
    #expect(draft.model.isEmpty)
    #expect(draft.effort.isEmpty)
    #expect(draft.permissionMode.isEmpty)
  }
}
