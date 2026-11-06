import Testing

@testable import OmnigentUIComponents

@Suite("Sidebar paging")
@MainActor
struct SidebarPagingTests {
  @Test("a folder lists five rows, five more per Show more, never past its members")
  func folderRows() {
    #expect(ProjectFolderPaging.visibleCount(count: 12, shown: 0, selectedIndex: nil) == 5)
    #expect(ProjectFolderPaging.visibleCount(count: 12, shown: 10, selectedIndex: nil) == 10)
    #expect(ProjectFolderPaging.visibleCount(count: 12, shown: 15, selectedIndex: nil) == 12)
    #expect(ProjectFolderPaging.visibleCount(count: 3, shown: 0, selectedIndex: nil) == 3)
  }

  @Test("the open session is never hidden under Show more")
  func revealsSelection() {
    #expect(ProjectFolderPaging.visibleCount(count: 20, shown: 0, selectedIndex: 4) == 5)
    #expect(ProjectFolderPaging.visibleCount(count: 20, shown: 0, selectedIndex: 5) == 10)
    #expect(ProjectFolderPaging.visibleCount(count: 20, shown: 0, selectedIndex: 13) == 15)
  }

  @Test("Load more reads by itself three times per scope, then waits for a click")
  func autoLoadBudget() {
    let budget = SidebarAutoLoads()
    #expect((0..<4).map { _ in budget.take(in: "all") } == [true, true, true, false])
    #expect(budget.take(in: "mine"))
  }
}
