import Testing

@testable import OmnigentUIComponents

/// Control-Tab's switcher picks as the web's does: the session after the open one, wrapping.
@Suite("Recent sessions switcher")
struct RecentSessionsSwitcherTests {
  private let rows = ["a", "b", "c"].map { RecentSessionRow(id: $0, title: $0, agent: "Codex") }

  @Test("Control-Tab starts after the open session and Shift before it, wrapping")
  func firstSelection() {
    #expect(RecentSessionsSwitcherState(rows: rows, active: "a", offset: 1)?.selectedID == "b")
    #expect(RecentSessionsSwitcherState(rows: rows, active: "c", offset: 1)?.selectedID == "a")
    #expect(RecentSessionsSwitcherState(rows: rows, active: "a", offset: -1)?.selectedID == "c")
  }

  @Test("Without the open session listed it starts at the first row, or the last with Shift")
  func notListed() {
    #expect(RecentSessionsSwitcherState(rows: rows, active: nil, offset: 1)?.selectedID == "a")
    #expect(RecentSessionsSwitcherState(rows: rows, active: "z", offset: -1)?.selectedID == "c")
    #expect(RecentSessionsSwitcherState(rows: [], active: "a", offset: 1) == nil)
  }

  @Test("Each Tab moves down and Shift-Tab up, wrapping at the ends")
  func steps() throws {
    var state = try #require(RecentSessionsSwitcherState(rows: rows, active: "a", offset: 1))
    state.step(by: 1)
    #expect(state.selectedID == "c")
    state.step(by: 1)
    #expect(state.selectedID == "a")
    state.step(by: -1)
    #expect(state.selectedID == "c")
  }
}
