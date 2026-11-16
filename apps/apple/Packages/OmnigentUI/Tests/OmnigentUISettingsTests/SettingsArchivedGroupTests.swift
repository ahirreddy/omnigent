import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Archived sessions under date labels")
struct SettingsArchivedGroupTests {
  /// 2026-11-04 14:40 UTC.
  private let now = Date(timeIntervalSince1970: 1_793_880_000)

  private func calendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
    return calendar
  }

  private func session(_ id: String, daysAgo: Double) -> SessionSummary {
    var session = PreviewData.sessions[0]
    session.id = id
    session.updatedAt = Int64(now.timeIntervalSince1970 - daysAgo * 86_400)
    return session
  }

  @Test("sessions out of order share one group per label, so no label repeats")
  func noDuplicateLabels() {
    let sessions = [
      session("today-1", daysAgo: 0.1), session("old", daysAgo: 90),
      session("today-2", daysAgo: 0.2), session("week", daysAgo: 3),
      session("old-2", daysAgo: 91), session("yesterday", daysAgo: 1),
      session("week-2", daysAgo: 4),
    ]
    let groups = ArchivedGroup.groups(sessions, now: now, calendar: calendar())
    let labels = groups.map(\.label)
    #expect(Set(labels).count == labels.count, "duplicate labels: \(labels)")
    #expect(groups.flatMap(\.sessions).count == sessions.count)
    #expect(groups.first { $0.label == "Today" }?.sessions.map(\.id) == ["today-1", "today-2"])
    #expect(
      groups.first { $0.label == "Previous 7 days" }?.sessions.map(\.id) == ["week", "week-2"])
  }

  @Test("groups keep the order their first session came in")
  func groupOrder() {
    let sessions = [
      session("week", daysAgo: 3), session("today", daysAgo: 0.1), session("week-2", daysAgo: 4),
    ]
    let groups = ArchivedGroup.groups(sessions, now: now, calendar: calendar())
    #expect(groups.map(\.label) == ["Previous 7 days", "Today"])
  }

  @Test("nothing archived makes no groups")
  func empty() {
    #expect(ArchivedGroup.groups([], now: now, calendar: calendar()).isEmpty)
  }

  @Test("each boundary falls in the newer group")
  func boundaries() {
    let utc = calendar()
    let today = utc.startOfDay(for: now)
    func label(daysBeforeToday days: Double, plus seconds: TimeInterval = 0) -> String {
      ArchivedGroup.label(
        today.addingTimeInterval(-days * 86_400 + seconds), now, utc)
    }
    #expect(label(daysBeforeToday: 0) == "Today")
    #expect(label(daysBeforeToday: 0, plus: -1) == "Yesterday")
    #expect(label(daysBeforeToday: 1) == "Yesterday")
    #expect(label(daysBeforeToday: 1, plus: -1) == "Previous 7 days")
    #expect(label(daysBeforeToday: 7) == "Previous 7 days")
    #expect(label(daysBeforeToday: 7, plus: -1) == "Previous 30 days")
    #expect(label(daysBeforeToday: 30) == "Previous 30 days")
    #expect(label(daysBeforeToday: 30, plus: -1).contains("2026"))
  }

  @Test("a session changed later than now reads as Today")
  func future() {
    #expect(ArchivedGroup.label(now.addingTimeInterval(86_400 * 400), now, calendar()) == "Today")
  }

  @Test("the month label is the month in the given calendar's time zone")
  func monthLabelUsesCalendarZone() {
    // 2026-02-01 03:00 UTC is still January in Los Angeles.
    let date = Date(timeIntervalSince1970: 1_769_914_800)
    let losAngeles = ArchivedGroup.label(date, now, calendar("America/Los_Angeles"))
    let tokyo = ArchivedGroup.label(date, now, calendar("Asia/Tokyo"))
    #expect(losAngeles.contains("2026"))
    #expect(tokyo.contains("2026"))
    #expect(losAngeles != tokyo, "\(losAngeles) and \(tokyo)")
  }

  @Test("retention reads only whole positive days")
  func retentionDays() {
    #expect(ArchivedRetention.days("30") == 30)
    #expect(ArchivedRetention.days(nil) == nil)
    for hostile in ["0", "-7", "", "seven", "1.5", " 7", "99999999999999999999"] {
      #expect(ArchivedRetention.days(hostile) == nil, "\(hostile)")
    }
    #expect(ArchivedRetention.title(nil) == "Never")
    #expect(ArchivedRetention.title(7) == "After 7 days")
    #expect(ArchivedRetention.choices.contains(nil))
  }

  @Test("a retention too large to be a time span keeps everything")
  func retentionOverflow() {
    let info = ["a": ArchivedSessionInfo(archivedAt: 0, canDelete: true)]
    let sessions = [session("a", daysAgo: 1)]
    #expect(ArchivedRetention.expired(sessions, info: info, days: Int.max, now: now).isEmpty)
    #expect(ArchivedRetention.expired(sessions, info: info, days: nil, now: now).isEmpty)
    #expect(ArchivedRetention.expired(sessions, info: info, days: 1, now: now) == ["a"])
    #expect(ArchivedRetention.expired(sessions, info: [:], days: 1, now: now).isEmpty)
  }
}
