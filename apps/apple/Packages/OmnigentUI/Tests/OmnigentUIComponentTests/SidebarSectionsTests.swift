import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Sidebar grouping")
struct SidebarSectionsTests {
  @Test("status grouping keeps Pinned on top and uses the web's buckets")
  func statusSections() {
    var state = PreviewData.sidebar
    state.display.groupBy = .status
    let sections = SidebarSections.sections(state)
    #expect(
      sections.map(\.title) == ["Pinned", "Needs attention", "Unread", "Working", "Done"])
    let ids = Dictionary(uniqueKeysWithValues: sections.map { ($0.title, $0.sessions.map(\.id)) })
    #expect(ids["Pinned"] == ["sess_p1"])
    // Pending and failed share a bucket; unread wins over a draft.
    #expect(ids["Needs attention"] == ["sess_a2", "sess_a3"])
    #expect(ids["Unread"] == ["sess_y1"])
    #expect(sections[1].showsDisplayMenu)
  }

  @Test("status grouping keeps an empty Working section")
  func statusKeepsWorking() {
    var state = PreviewData.sidebar
    state.display.groupBy = .status
    state.list.sessions = state.list.sessions.filter { $0.attention != .working }
    #expect(
      SidebarSections.sections(state).first { $0.title == "Working" }?.sessions.isEmpty == true)
  }

  @Test("date and harness grouping use the web's titles and order")
  func dateAndHarnessSections() {
    var state = PreviewData.sidebar
    state.display.groupBy = .updated
    #expect(
      SidebarSections.sections(state).map(\.title) == [
        "Pinned", "Updated today", "Updated yesterday", "Updated in the last 7 days",
        "Updated in the last 30 days", "Updated earlier",
      ])
    state.display.groupBy = .harness
    let harness = SidebarSections.sections(state).dropFirst().map(\.title)
    #expect(harness == harness.sorted { $0.localizedCompare($1) == .orderedAscending })
  }

  @Test("date buckets follow local midnights, seven and thirty days back inclusive")
  func dateBuckets() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9)))
    let daysAgo = { (days: Int) in
      calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
    }
    let bucket = { (date: Date) in SidebarSections.dateBucket(date, now: now, calendar: calendar) }
    #expect(bucket(daysAgo(0)) == "today")
    #expect(bucket(daysAgo(0).addingTimeInterval(-1)) == "yesterday")
    #expect(bucket(daysAgo(7)) == "in the last 7 days")
    #expect(bucket(daysAgo(8)) == "in the last 30 days")
    #expect(bucket(daysAgo(30)) == "in the last 30 days")
    #expect(bucket(daysAgo(30).addingTimeInterval(-1)) == "earlier")
  }
}
