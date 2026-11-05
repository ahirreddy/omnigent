import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
@Suite("Usage and Inbox mapping")
struct PagesAdapterTests {
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
