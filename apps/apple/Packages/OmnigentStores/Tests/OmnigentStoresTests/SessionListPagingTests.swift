import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

@MainActor
struct SessionListPagingTests {
  @Test("the core's report drives Load more, and a reset or clear drops it")
  func pagingFollowsTheCore() {
    let store = SessionListStore()
    store.paging.pagingChanged(hasMore: true, isLoading: true)
    #expect(store.paging.hasMore)
    #expect(store.paging.isLoading)
    store.paging.pagingChanged(hasMore: true, isLoading: false)
    #expect(!store.paging.isLoading)
    store.clear()
    #expect(!store.paging.hasMore)
  }

  @Test("a folder has more until its first page is read and while pages are left")
  func folderPagesHaveMore() {
    var pages = SessionListPaging.ProjectPages()
    #expect(pages.hasMore)
    pages.isLoaded = true
    pages.hasMoreAfter = true
    #expect(pages.hasMore)
    pages.hasMoreAfter = false
    #expect(!pages.hasMore)
  }

  @Test("folders follow the core's report; a list reset leaves them and a clear drops them")
  func foldersFollowTheCore() {
    let store = SessionListStore()
    store.paging.foldersChanged([
      ProjectFolderPaging(folderId: "p1", isLoaded: true, hasMoreAfter: true, isLoading: false)
    ])
    #expect(store.paging.projects["p1"]?.hasMore == true)
    // The core reads the open folders again with a reload; their pages stay meanwhile.
    store.apply(.reset(sessions: []))
    #expect(store.paging.projects["p1"]?.isLoaded == true)
    store.paging.foldersChanged([])
    #expect(store.paging.projects.isEmpty)
    store.paging.foldersChanged([
      ProjectFolderPaging(folderId: "p1", isLoaded: false, hasMoreAfter: false, isLoading: true)
    ])
    store.clear()
    #expect(store.paging.projects.isEmpty)
  }

  @Test("projects the core read replace the last ones and clear their failure")
  func projectsFollowTheCore() {
    let store = SessionListStore()
    store.projectsError = .InvalidState(message: "boom")
    let alpha = ProjectSummary(id: "p1", name: "Alpha", icon: nil)
    store.projectsLoaded([alpha], sortMode: .manual)
    #expect(store.projects == [alpha])
    #expect(store.projectSortMode == .manual)
    #expect(store.projectsError == nil)
  }

  @Test("without a core, Load more and a folder read do nothing")
  func noCoreLoadsNothing() {
    let paging = SessionListPaging()
    paging.pagingChanged(hasMore: true, isLoading: false)
    paging.loadMore()
    #expect(!paging.isLoading)
    paging.loadProject(.init(id: "p1", name: "Work", icon: nil))
    paging.setOpenFolders(["p1"])
    #expect(paging.projects.isEmpty)
  }
}
