import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Server settings panes")
struct ServerSettingsPaneTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }

  private func session(_ id: String, daysAgo: Double, from now: Date) -> SessionSummary {
    var session = PreviewData.sessions[0]
    session.id = id
    session.updatedAt = Int64(now.timeIntervalSince1970 - daysAgo * 86_400)
    return session
  }

  @Test("Archived sessions group under the web's date labels, in order")
  func archivedGroups() {
    let now = Date(timeIntervalSince1970: 1_793_880_000)  // 2026-11-04 14:40 UTC
    let sessions = [
      session("a", daysAgo: 0.1, from: now), session("b", daysAgo: 1, from: now),
      session("c", daysAgo: 3, from: now), session("d", daysAgo: 4, from: now),
      session("e", daysAgo: 20, from: now), session("f", daysAgo: 90, from: now),
    ]
    let groups = ArchivedGroup.groups(sessions, now: now, calendar: calendar)
    #expect(
      groups.map(\.label).prefix(4)
        == ["Today", "Yesterday", "Previous 7 days", "Previous 30 days"])
    #expect(groups.map { $0.sessions.map(\.id) }.prefix(4) == [["a"], ["b"], ["c", "d"], ["e"]])
    #expect(groups.count == 5, "an older session is labelled with its month and year")
  }

  @Test("Admin panes are grouped apart from the rest")
  func adminPanes() {
    #expect(ServerSettingsPane.allCases.filter(\.isAdmin) == [.members, .policies, .sharing])
  }
}
