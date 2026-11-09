import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Usage amounts and ranges")
struct PagesUsageLogicTests {
  private func calendar(_ identifier: Calendar.Identifier = .gregorian) -> Calendar {
    var calendar = Calendar(identifier: identifier)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
    return calendar
  }

  /// The day a label lands on, read back in the Gregorian calendar: year/month/day hour.
  private func landing(_ label: String, in calendar: Calendar) -> String? {
    UsageAmount(label: label, costUSD: 1).day(in: calendar).map { date in
      var gregorian = Calendar(identifier: .gregorian)
      gregorian.timeZone = calendar.timeZone
      let found = gregorian.dateComponents([.year, .month, .day, .hour], from: date)
      return "\(found.year ?? -1)/\(found.month ?? -1)/\(found.day ?? -1) \(found.hour ?? -1)"
    }
  }

  @Test("a daily label is the start of that local day")
  func validDays() {
    #expect(landing("2026-11-04", in: calendar()) == "2026/11/4 0")
    #expect(landing("2024-02-29", in: calendar()) == "2024/2/29 0")
    #expect(landing("0001-01-01", in: calendar())?.hasPrefix("1/1/1") == true)
    #expect(landing("9999-12-31", in: calendar()) == "9999/12/31 0")
  }

  @Test(
    "a label that isn't a real day has no bar, instead of rolling over to another day",
    arguments: [
      "2026-13-45", "2026-00-00", "2026-02-30", "2025-02-29", "2026-04-31", "2026-11-00",
      "2026-00-10", "2026--1-01", "x-2026-1-1", "26-11-04-1", "2026/11/04", "2026-1-004",
      "20261104", "", "----------", "not-a-date", "٢٠٢٦-١١-٠٤", "+026-11-04", "2026-11-+4",
      "2026-11-04 ", " 2026-11-04", "2026-11-04T00",
    ])
  func invalidDays(label: String) {
    #expect(UsageAmount(label: label, costUSD: 1).day(in: calendar()) == nil, "\(label)")
  }

  @Test("a report's days are Gregorian, whatever calendar the Mac is set to")
  func otherCalendars() {
    for identifier in [Calendar.Identifier.buddhist, .japanese, .hebrew, .islamicCivil, .persian] {
      #expect(landing("2026-11-04", in: calendar(identifier)) == "2026/11/4 0", "\(identifier)")
    }
  }

  @Test("each range has its label and length")
  func ranges() {
    #expect(
      UsageRange.allCases.map(\.title) == ["7 days", "30 days", "90 days", "All time", "Custom"])
    #expect(UsageRange.allCases.map(\.days) == [7, 30, 90, nil, nil])
    #expect(UsageRange.allCases.map(\.id) == UsageRange.allCases)
  }

  @Test("the sort menu labels and ids follow the table's columns")
  func sortTitles() {
    #expect(UsageSessionSort.allCases.map(\.title) == ["Last active", "Cost", "Session"])
    #expect(UsageSessionSort.allCases.map(\.id) == UsageSessionSort.allCases)
  }
}
