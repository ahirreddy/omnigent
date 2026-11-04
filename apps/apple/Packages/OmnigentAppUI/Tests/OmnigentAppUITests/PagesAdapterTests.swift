import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
@Suite("Automations, Usage and Inbox mapping")
struct PagesAdapterTests {
  private func automation(rrule: String) -> Automation {
    Automation(
      id: "t1", name: "Standup", prompt: "Summarize", rrule: rrule,
      scheduleText: describeSchedule(rrule: rrule), agentId: "a1", timezone: "Europe/Paris",
      continuesSession: true, state: .active, nextRunAt: nil, lastRunAt: nil,
      lastRunStatus: nil, lastRunSessionId: nil, updatedAt: 0)
  }

  @Test("An editable rule round-trips through the editor; the device zone is not forced on it")
  func editableRule() {
    let rule = "FREQ=WEEKLY;BYDAY=MO,FR;BYHOUR=8;BYMINUTE=30"
    let draft = AutomationsMapping.draft(automation(rrule: rule))
    #expect(draft.schedule?.preset == .weekly)
    #expect(draft.schedule?.weekdays == [0, 4])
    #expect(draft.keptRule == nil)
    #expect(draft.continuesSession)
    #expect(
      AutomationsMapping.describe(draft.schedule ?? ScheduleChoice())
        == "Weekly on Monday and Friday at 8:30 AM")
    let request = AutomationsMapping.request(
      draft, keptRule: rule, timezone: "Europe/Paris", sessionModes: false)
    #expect(request.rrule == rule)
    #expect(request.timezone == "Europe/Paris")
    #expect(request.continuesSession == nil)
  }

  @Test("A rule the editor cannot show is kept as it is")
  func keptRule() {
    let rule = "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;COUNT=5"
    let draft = AutomationsMapping.draft(automation(rrule: rule))
    #expect(draft.schedule == nil)
    #expect(draft.keptRule == "Every day at 8:00 AM")
    let request = AutomationsMapping.request(
      draft, keptRule: rule, timezone: "UTC", sessionModes: true)
    #expect(request.rrule == rule)
    #expect(request.continuesSession == true)
  }

  @Test("A suggestion fills a new automation with the first agent that can start sessions")
  func suggestion() throws {
    let suggestion = try #require(AutomationSuggestion.all.first)
    let draft = AutomationsMapping.newDraft(suggestion, agents: [])
    #expect(draft.name == suggestion.title)
    #expect(draft.prompt == suggestion.prompt)
    #expect(draft.agentID.isEmpty)
    #expect(!draft.canSave)
    #expect(
      AutomationsMapping.describe(suggestion.schedule) == "Weekdays at 9:00 AM")
  }

  @Test("Usage presets start on the web's day; custom ranges use local calendar days")
  func usageBounds() throws {
    let now = Date(timeIntervalSince1970: 1_793_865_600)  // 2026-11-05 08:00 UTC
    let week = UsageMapping.bounds(.init(range: .week, start: nil, end: nil), now: now)
    #expect(week.0 == "2026-10-30")
    #expect(week.1 == nil)
    let all = UsageMapping.bounds(.init(range: .all, start: nil, end: nil), now: now)
    #expect(all.0 == nil && all.1 == nil)
    let start = try #require(
      Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 4)))
    let end = try #require(
      Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 9)))
    let custom = UsageMapping.bounds(.init(range: .custom, start: start, end: end), now: now)
    #expect(custom.0 == "2026-03-04")
    #expect(custom.1 == "2026-03-09")
  }

  @Test("Usage shows loading, failure and a narrowed report")
  func usageState() {
    #expect(UsageMapping.state(.loading, window: .init(range: .all), now: .now).isLoading)
    let failed = UsageMapping.state(
      .failed(.InvalidState(message: "down")), window: .init(range: .all), now: .now)
    #expect(failed.loadError == "down")
    #expect(!failed.isLoading)
    let report = UsageReport(
      dailyCosts: [DailyCost(day: "2026-11-01", costUsd: 1.5)],
      sessions: [
        SessionUsage(
          id: "s1", title: nil, createdAt: 0, updatedAt: 1_793_520_000, costUsd: 1.5,
          models: [
            ModelCost(model: "opus", costUsd: 1.0), ModelCost(model: "haiku", costUsd: 0.5),
          ],
          harness: nil)
      ])
    let state = UsageMapping.state(.loaded(report), window: .init(range: .all), now: .now)
    #expect(state.totalText == "$1.50")
    #expect(state.sessions.first?.title == "Untitled")
    #expect(state.sessions.first?.model == "opus +1")
    #expect(state.sessions.first?.harness == "\u{2014}")
  }

  @Test("Comment items carry their comment id; others carry none")
  func commentIDs() {
    let comment = InboxItem(
      id: "comment-c1", kind: .comment, sessionId: "s", sessionTitle: "", preview: "", date: .now)
    #expect(InboxTriageMapping.commentID(comment) == "c1")
    let session = InboxItem(
      id: "session-s", kind: .unread, sessionId: "s", sessionTitle: "", preview: "", date: .now)
    #expect(InboxTriageMapping.commentID(session) == nil)
  }
}

extension UsageMapping.Window {
  fileprivate init(range: UsageRange) {
    self.init(range: range, start: nil, end: nil)
  }
}
