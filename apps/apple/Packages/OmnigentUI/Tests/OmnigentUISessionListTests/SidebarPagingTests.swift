import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Sidebar paging")
@MainActor
struct SidebarPagingTests {
  private let size = ProjectFolderPaging.pageSize

  @Test("a folder lists a page of rows, a page more per Show more, never past its members")
  func folderRows() {
    let count = size * 2 + 2
    #expect(ProjectFolderPaging.visibleCount(count: count, shown: 0, selectedIndex: nil) == size)
    #expect(
      ProjectFolderPaging.visibleCount(count: count, shown: size * 2, selectedIndex: nil)
        == size * 2)
    #expect(
      ProjectFolderPaging.visibleCount(count: count, shown: size * 3, selectedIndex: nil) == count)
    #expect(ProjectFolderPaging.visibleCount(count: 3, shown: 0, selectedIndex: nil) == 3)
    // Show All Sessions lists every member.
    #expect(
      ProjectFolderPaging.visibleCount(
        count: 500, shown: ProjectFolderPaging.all, selectedIndex: nil) == 500)
  }

  @Test("the open session is never hidden under Show more")
  func revealsSelection() {
    let count = size * 4
    let visible = { (index: Int) in
      ProjectFolderPaging.visibleCount(count: count, shown: 0, selectedIndex: index)
    }
    #expect(visible(size - 1) == size)
    #expect(visible(size) == size * 2)
    #expect(visible(size * 2 + 3) == size * 3)
  }

  @Test("Show All Sessions is kept per project")
  func showAllIsKept() throws {
    let suite = "show-all-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(ProjectShowAll.shown("work", in: defaults) == 0)
    ProjectShowAll.set("work", true, in: defaults)
    ProjectShowAll.set("home", true, in: defaults)
    ProjectShowAll.set("home", false, in: defaults)
    #expect(ProjectShowAll.shows("work", in: defaults))
    #expect(!ProjectShowAll.shows("home", in: defaults))
    #expect(ProjectShowAll.shown("work", in: defaults) == ProjectFolderPaging.all)
  }

  @Test("Load more reads by itself three times per scope, then waits for a click")
  func autoLoadBudget() {
    let budget = SidebarAutoLoads()
    #expect((0..<4).map { _ in budget.take(in: "all") } == [true, true, true, false])
    #expect(budget.take(in: "mine"))
  }
}
