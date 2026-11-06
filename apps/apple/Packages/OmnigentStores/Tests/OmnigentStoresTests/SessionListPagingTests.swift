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

  @Test("a folder has more until its first page is read and while a cursor is left")
  func folderPagesHaveMore() {
    var pages = SessionListPaging.ProjectPages()
    #expect(pages.hasMore)
    pages.isLoaded = true
    pages.nextCursor = "s_20"
    #expect(pages.hasMore)
    pages.nextCursor = nil
    #expect(!pages.hasMore)
  }

  @Test("without a core, Load more and a folder read do nothing")
  func noCoreLoadsNothing() async {
    let paging = SessionListPaging()
    paging.pagingChanged(hasMore: true, isLoading: false)
    paging.loadMore()
    #expect(!paging.isLoading)
    await paging.loadProject(.init(id: "p1", name: "Work", icon: nil), id: "p1")
    #expect(paging.projects.isEmpty)
  }
}
