import Foundation

@testable import OmnigentUIComponents

/// A family of three sessions, Coordinator (its representative and source), Implementation and
/// Review, beside a session of its own, Solo. In the list's order (most recent first)
/// Implementation leads, so the family stands first.
enum FamilyFixture {
  static let familyID = "coord"
  static let family = SessionFamilyInfo(
    id: familyID, representativeID: "coord", representativeTitle: "Coordinator")

  /// A member of `family`, nested unless it is the representative, as the core reports it: a
  /// nested member can't be pinned on its own.
  static func member(
    _ id: String, _ title: String, updatedAt: Int64, family: SessionFamilyInfo = family,
    isPinned: Bool = false, attention: SessionAttentionState? = nil
  ) -> SessionSummary {
    let isNested = family.representativeID.map { $0 != id } ?? false
    return SessionSummary(
      id: id, title: title, updatedAt: updatedAt, isPinned: isPinned, canPin: !isNested,
      attention: attention, isNestedMember: isNested, family: family)
  }

  static var coordinator: SessionSummary { member("coord", "Coordinator", updatedAt: 500) }
  static var implementation: SessionSummary { member("impl", "Implementation", updatedAt: 900) }
  static var review: SessionSummary { member("review", "Review", updatedAt: 300) }
  static let solo = SessionSummary(id: "solo", title: "Solo", updatedAt: 700)

  /// Creation times: the representative first, then Implementation, then Review.
  static let created: [String: Int64] = ["coord": 100, "impl": 200, "review": 300, "solo": 50]

  /// The list's order: Implementation, Solo, Coordinator, Review.
  static var sessions: [SessionSummary] { [implementation, solo, coordinator, review] }

  /// A sidebar of `sessions` (the fixture's by default), each with its creation time.
  static func state(_ sessions: [SessionSummary] = sessions) -> SidebarViewState {
    var state = SidebarViewState(list: SessionListViewState(sessions: sessions))
    state.rowInfo = created.mapValues { SessionRowInfo(createdAt: $0) }
    return state
  }

  /// The family pinned by its representative's pin, as the server reports a family pin.
  static var pinnedState: SidebarViewState {
    let pinnedFamily = SessionFamilyInfo(
      id: familyID, representativeID: "coord", representativeTitle: "Coordinator",
      isPinned: true, pinnedAt: "1700000000000")
    return state([
      member("coord", "Coordinator", updatedAt: 500, family: pinnedFamily, isPinned: true),
      member("impl", "Implementation", updatedAt: 900, family: pinnedFamily),
      solo, member("review", "Review", updatedAt: 300, family: pinnedFamily),
    ])
  }

  static func ids(_ sessions: [SessionSummary]) -> [String] { sessions.map(\.id) }
}
