import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentStores

nonisolated private let prURL = "https://github.com/o/r/pull/7"
nonisolated private let github = "/v1/sessions/conv_a/resources/github"
nonisolated private let head = "1111111111111111111111111111111111111111"
nonisolated private let base = "2222222222222222222222222222222222222222"

/// Two hunks of `src/a.txt` 17 lines apart, and a renamed file.
nonisolated private let twoHunks = """
  diff --git a/src/a.txt b/src/a.txt
  --- a/src/a.txt
  +++ b/src/a.txt
  @@ -2,3 +2,3 @@
   two
  -three
  +THREE
   four
  @@ -20,3 +20,3 @@
   twenty
  -twentyone
  +TWENTYONE
   twentytwo
  diff --git a/old.txt b/new.txt
  rename from old.txt
  rename to new.txt
  --- a/old.txt
  +++ b/new.txt
  @@ -1 +1 @@
  -x
  +y

  """

nonisolated private func json(_ object: [String: Any]) throws -> String {
  try #require(
    String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
}

nonisolated private func info(commits: Bool = true) -> String {
  #"""
  {"object":"session.github.info","available":true,"provider":"github",
   "repo":{"name_with_owner":"o/r"},"auth":{"authenticated":true},
   "provider_display":{"display_name":"GitHub","number_prefix":"#"},
   "capabilities":{"review_threads":false,"review_thread_creation":true,
                   "commit_history":\#(commits)},
   "selected_pr_url":"\#(prURL)","tracking_available":true,
   "prs":[{"url":"\#(prURL)","host":"github.com","repository":"o/r","number":7,
           "relationship":"created","state":"OPEN","provider":"github"}],
   "pr":{"number":7,"title":"Fix","state":"OPEN","url":"\#(prURL)","head_sha":"\#(head)",
         "base_sha":"\#(base)","head_repository_url":"https://github.com/fork/r",
         "checks":{"passing":1,"failing":0,"pending":0,"total":1}}}
  """#
}

nonisolated private let changes = #"""
  {"object":"list","data":[
    {"path":"src/a.txt","name":"a.txt","status":"modified","lines_added":2,"lines_removed":2},
    {"path":"new.txt","name":"new.txt","status":"renamed","lines_added":1,"lines_removed":1,
     "previous_path":"old.txt"},
    {"path":"bin.png","name":"bin.png","status":"created","lines_added":null,
     "lines_removed":null}],
   "has_more":false,"total_count":3,
   "head_sha":"1111111111111111111111111111111111111111",
   "base_sha":"2222222222222222222222222222222222222222"}
  """#

@MainActor
private func opened(
  _ server: RouteServer = RouteServer(), patch: String = twoHunks, commits: Bool = true,
  anchors: Bool = false, defaults: UserDefaults? = nil
) async throws -> (RouteServer, SessionPanelStore) {
  server.route(
    "/v1/info",
    .json(
      #"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true,"comment_anchor_metadata":\#(anchors)}"#
    ))
  server.route(github, .json(info(commits: commits)))
  server.route("\(github)/changes", .json(changes))
  server.route(
    "\(github)/diff",
    .json(
      try json([
        "object": "session.github.pr_diff", "patch": patch, "head_sha": head, "base_sha": base,
      ])))
  let connection = try await connectedStore(server)
  let suite = try defaults ?? #require(UserDefaults(suiteName: "pr-changes-\(UUID().uuidString)"))
  let store = SessionPanelStore(
    sessionID: "conv_a", core: try #require(connection.core),
    viewedMarks: PullRequestViewedMarks(defaults: suite), preferences: suite)
  store.viewedScope = { PullRequestViewedScope(server: "http://127.0.0.1:6767", user: "local") }
  await store.loadFeatures()
  await store.showPullRequest(prURL)
  return (server, store)
}

/// The Changes tab over main's host shapes: the pinned list and patch, filters, viewed marks,
/// find, expanding context, commits and "Changes since".
@MainActor
@Suite("Pull request changes", .timeLimit(.minutes(1)))
struct PullRequestChangesTests {
  @Test("The list and the patch are read at the revision the detail shows, and merge by path")
  func pinnedList() async throws {
    let (server, store) = try await opened()
    for route in ["\(github)/changes", "\(github)/diff"] {
      let request = try #require(server.requests(to: route).last)
      let query = URLComponents(string: request.url)?.queryItems ?? []
      #expect(query.first { $0.name == "head_sha" }?.value == head, "\(route)")
      #expect(query.first { $0.name == "base_sha" }?.value == base, "\(route)")
    }
    let files = store.listedFiles
    #expect(files.map(\.path) == ["src/a.txt", "new.txt", "bin.png"])
    #expect(files[1].kind == .renamed && files[1].renamedFrom == "old.txt")
    #expect(files[1].diff != nil, "a rename finds its diff")
    #expect(files[2].diff == nil && files[2].added == nil, "no text, no counts")
    #expect(store.renderedHead == head)
  }

  @Test("The path filter matches old paths and either slash; hiding viewed files drops them")
  func filters() async throws {
    let (_, store) = try await opened()
    store.setPathFilter("OLD")
    #expect(store.visibleFiles.map(\.path) == ["new.txt"])
    store.setPathFilter("src\\a")
    #expect(store.visibleFiles.map(\.path) == ["src/a.txt"])
    store.setPathFilter("")
    store.toggleViewed("src/a.txt")
    store.setHideViewed(true)
    #expect(store.visibleFiles.map(\.path) == ["new.txt", "bin.png"])
    store.showHiddenFiles()
    #expect(store.visibleFiles.count == 3 && !store.changesView.hideViewed)
  }

  @Test("A viewed mark collapses its file and holds on a new head while its hunks are the same")
  func viewedMarks() async throws {
    let defaults = try #require(UserDefaults(suiteName: "pr-viewed-\(UUID().uuidString)"))
    let (server, store) = try await opened(defaults: defaults)
    #expect(store.viewedAvailable)
    store.toggleViewed("src/a.txt")
    store.toggleViewed("bin.png")
    #expect(store.viewedState.viewed == ["src/a.txt", "bin.png"])
    #expect(store.isCollapsed("src/a.txt"))

    // The same session reopened reads the marks back.
    let (_, again) = try await opened(server, defaults: defaults)
    #expect(again.viewedState.viewed == ["src/a.txt", "bin.png"])
    #expect(again.isCollapsed("src/a.txt"), "viewed files start collapsed")

    // A new head: the unchanged hunks keep their mark, a changed file says so, and a file
    // without text was marked for the old head only.
    let newHead = "3333333333333333333333333333333333333333"
    server.route(
      github, .json(info().replacingOccurrences(of: head, with: newHead)))
    let edited = twoHunks.replacingOccurrences(of: "+TWENTYONE", with: "+21")
    server.route(
      "\(github)/changes", .json(changes.replacingOccurrences(of: head, with: newHead)))
    server.route(
      "\(github)/diff",
      .json(
        try json([
          "object": "session.github.pr_diff", "patch": edited, "head_sha": newHead,
          "base_sha": base,
        ])))
    await again.reloadDetail()
    #expect(again.renderedHead == newHead)
    #expect(again.viewedState.viewed.isEmpty)
    #expect(again.viewedState.changed == ["src/a.txt"])
    #expect(!again.isCollapsed("src/a.txt"), "a mark's collapse ends with the mark")

    again.toggleViewed("src/a.txt")
    again.toggleViewed("src/a.txt")
    #expect(again.viewedState.viewed.isEmpty && again.viewedState.changed.isEmpty)
  }

  @Test("Find seeds the match at the top of the view, steps with wrapping and counts hidden files")
  func find() async throws {
    let (_, store) = try await opened()
    store.openFind()
    store.setFindQuery("t")
    let matches = store.findResults.visible.matches
    #expect(!matches.isEmpty)
    #expect(store.activeFindIndex(matches) == 0)
    let first = store.changesView.scroll
    store.stepFind(forward: false)
    #expect(store.activeFindIndex(matches) == matches.count - 1, "back from the first wraps")
    #expect(store.changesView.scroll != first)

    store.setFindQuery("THREE")
    #expect(store.findResults.visible.matches.count == 2, "case-insensitive by default")
    store.toggleFindMatchCase()
    let exact = store.findResults.visible.matches
    #expect(exact.count == 1 && exact[0].target.line == 3 && exact[0].target.side == .new)
    if case .line(let path, let side, let line) = store.changesView.scroll?.target {
      #expect((path, side, line) == ("src/a.txt", .new, 3))
    } else {
      Issue.record("a line match scrolls to its line")
    }

    store.setPathFilter("new")
    #expect(store.findResults.visible.matches.isEmpty)
    #expect(store.findResults.hidden.matches.count == 1)

    store.setPathFilter("")
    store.toggleFindRegex()
    store.setFindQuery("(")
    #expect(store.findResults.visible.invalid)
    store.closeFind()
    #expect(store.findResults.visible.matches.isEmpty && store.changesView.findTarget == nil)
  }

  @Test("Expanding context reads the file at the revision and shows ten lines at a time")
  func expandsContext() async throws {
    let (server, store) = try await opened()
    let lines = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
    server.route(
      "\(github)/diff/src/a.txt",
      .json(
        try json([
          "object": "session.github.file_diff", "path": "src/a.txt", "before": lines,
          "after": lines,
        ])))
    let diff = try #require(store.listedFiles.first?.diff)
    let gaps = DiffContext.gaps(diff, lineCount: nil)
    #expect(gaps.map(\.index) == [0, 1, 2])
    #expect(gaps[1].count == 15 && gaps[2].count == nil)
    await store.expandContext("src/a.txt", gap: gaps[1], .below)
    let request = try #require(server.requests(to: "\(github)/diff/src/a.txt").last)
    let query = URLComponents(string: request.url)?.queryItems ?? []
    #expect(query.first { $0.name == "head_sha" }?.value == head)
    #expect(query.first { $0.name == "pr_url" }?.value == prURL)
    let state = try #require(store.fileContext["src/a.txt"])
    #expect(state.text?.lines.count == 30)
    #expect(state.reveals[1] == DiffGapReveal(top: 10, bottom: 0))
    await store.expandContext("src/a.txt", gap: gaps[2], .all)
    #expect(store.fileContext["src/a.txt"]?.reveals[2]?.top == 8, "lines 23 to 30")
  }

  @Test("Commits list at the listed head; a commit's patch and the changes since one replace it")
  func commits() async throws {
    let (server, store) = try await opened()
    server.route(
      "\(github)/commits",
      .json(
        #"{"object":"list","data":[{"sha":"\#(base)","title":"Parent","author":"Ann","date":"2026-01-01T00:00:00Z","head_of":[{"number":41,"url":null,"state":"OPEN"}]},{"sha":"\#(head)","title":"Fix","author":"Ann","date":null}],"has_more":false}"#
      ))
    let commitPatch = """
      diff --git a/c.txt b/c.txt
      new file mode 100644
      --- /dev/null
      +++ b/c.txt
      @@ -0,0 +1 @@
      +c

      """
    server.route(
      "\(github)/commit-diff",
      .json(try json(["object": "session.github.pr_diff", "patch": commitPatch])))
    server.route(
      "\(github)/compare-diff",
      .json(try json(["object": "session.github.pr_diff", "patch": commitPatch])))
    #expect(store.commitsSupported)
    store.setCommitsShown(true)
    try await eventually("the commits") { store.commits.value != nil }
    let read = try #require(server.requests(to: "\(github)/commits").last)
    #expect(read.url.contains("head_sha=\(head)"))
    #expect(store.commits.value?.commits.first?.headOf.first?.number == 41)

    store.openCommit(head)
    try await eventually("the commit's patch") { store.commitPatch.value != nil }
    #expect(store.listedFiles.map(\.path) == ["c.txt"] && store.listedFiles[0].kind == .added)
    #expect(!store.isReviewing)
    #expect(store.openCommitNeighbours.previous?.sha == base)
    #expect(store.openCommitNeighbours.next == nil)

    store.setCommitsShown(false)
    store.setSinceSha(base)
    try await eventually("the changes since") {
      !server.requests(to: "\(github)/compare-diff").isEmpty && store.commitPatch.value != nil
    }
    let compare = try #require(server.requests(to: "\(github)/compare-diff").last)
    #expect(compare.url.contains("from_sha=\(base)") && compare.url.contains("head_sha=\(head)"))
    #expect(store.showsPatchView)
    store.setSinceSha(nil)
    #expect(store.listedFiles.count == 3)
  }

  @Test("A server without the commit routes leaves only Changes, and says why")
  func commitsUnsupported() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/commits", status: 404, detail: "Not Found")
    store.setCommitsShown(true)
    try await eventually("the refusal") { !store.commitsSupported }
    #expect(store.changesMode == .changes)
    #expect(store.editError?.message == SessionPanelStore.commitsNeedNewerServer)

    let (_, plain) = try await opened(commits: false)
    #expect(!plain.commitsSupported)
  }

  @Test("Collapse All and toggles act on the view shown; a commit's collapses are its own")
  func collapses() async throws {
    let (_, store) = try await opened()
    let paths = store.visibleFiles.map(\.path)
    store.toggleAllCollapsed(paths)
    #expect(paths.allSatisfy { store.isCollapsed($0) })
    store.jumpToFile("new.txt")
    #expect(!store.isCollapsed("new.txt"), "a jump shows the file")
    store.toggleCollapsed("new.txt")
    #expect(store.isCollapsed("new.txt"))
    store.toggleAllCollapsed(paths)
    #expect(!paths.contains { store.isCollapsed($0) })
    store.diffLayout = .split
    #expect(store.preferences.string(forKey: SessionPanelStore.diffLayoutKey) == "split")
  }
}
