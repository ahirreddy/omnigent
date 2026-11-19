#if os(macOS)
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: project folder paging", .serialized)
  @MainActor
  struct SessionListProjectPagingTests {
    private let work = SessionProject(
      id: "p1", name: "Work", sessionIds: ["beta"], icon: "\u{1F680}")

    @Test("Show more lists a page more, and reads the next page when loaded rows run out")
    func showMore() throws {
      var calls: [Int] = []
      var loads = 0
      let size = ProjectFolderPaging.pageSize
      let sessions = (0..<size + 2).map { SessionSummary(id: "s\($0)", title: "S\($0)") }
      func pages(shown: Int) -> ProjectFolderPages {
        ProjectFolderPages(
          project: work, sessions: sessions, paging: SidebarPaging(), shown: shown, selection: nil,
          load: { _ in loads += 1 }, setShown: { calls.append($0) })
      }
      let first = pages(shown: 0)
      #expect(first.visibleCount == ProjectFolderPaging.pageSize)
      first.showMore()
      #expect(calls == [size * 2])
      #expect(loads == 1)
      first.load?()
      #expect(loads == 2)
      let noLoad = ProjectFolderPages(
        project: work, sessions: sessions, paging: SidebarPaging(), shown: 0,
        selection: .session("s\(size + 1)"),
        load: nil, setShown: { _ in })
      // The open session stays listed even past the first page.
      #expect(noLoad.visibleCount == sessions.count)
      noLoad.showMore()
      #expect(noLoad.load == nil)
    }

    @Test("Show All Sessions lists every member, reads the pages left, and is kept")
    func showAllSessions() throws {
      defer { ProjectShowAll.set(work.id, false) }
      var calls: [Int] = []
      var loads = 0
      let sessions = (0..<ProjectFolderPaging.pageSize + 2).map {
        SessionSummary(id: "s\($0)", title: "S\($0)")
      }
      var paging = SidebarPaging()
      paging.projectsWithMore = [work.id]
      func pages(shown: Int?) -> ProjectFolderPages {
        ProjectFolderPages(
          project: work, sessions: sessions, paging: paging, shown: shown, selection: nil,
          load: { _ in loads += 1 }, setShown: { calls.append($0) })
      }
      let off = pages(shown: nil)
      #expect(!off.showsAll)
      off.setShowsAll(true)
      #expect(calls == [ProjectFolderPaging.all])
      #expect(loads == 1, "the pages left are read")
      #expect(ProjectShowAll.shows(work.id))
      // A later launch starts with it on: every loaded member is listed.
      let kept = pages(shown: nil)
      #expect(kept.showsAll)
      #expect(kept.visibleCount == sessions.count)
      kept.setShowsAll(false)
      #expect(calls.last == 0)
      #expect(!ProjectShowAll.shows(work.id))
      #expect(pages(shown: nil).visibleCount == ProjectFolderPaging.pageSize)
    }
  }
#endif
