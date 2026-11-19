#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import OmnigentWorkspaceUI
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The pull request's Changes tab: its toolbar, find with Command-F, the file tree, the
  /// commit list and the file header's actions, as the web's Changes tab lays them out.
  @Suite("Inspector: pull request changes", .serialized)
  @MainActor
  struct InspectorPullRequestChangesTests {
    final class Calls {
      var log: [String] = []
    }

    private func actions(_ calls: Calls) -> PullRequestChangesActions {
      var actions = PullRequestChangesActions()
      actions.setFindOpen = { calls.log.append("find \($0)") }
      actions.setFindQuery = { calls.log.append("query \($0)") }
      actions.stepFind = { calls.log.append("step \($0)") }
      actions.toggleMatchCase = { calls.log.append("case") }
      actions.toggleRegex = { calls.log.append("regex") }
      actions.showHidden = { calls.log.append("show hidden") }
      actions.setLayout = { calls.log.append("layout \($0.rawValue)") }
      actions.toggleAll = { calls.log.append("toggle all") }
      actions.setHideViewed = { calls.log.append("hide \($0)") }
      actions.jumpToFile = { calls.log.append("jump \($0)") }
      actions.openCommit = { calls.log.append("open \($0)") }
      actions.showCommits = { calls.log.append("commits \($0)") }
      actions.setPathFilter = { calls.log.append("filter \($0)") }
      return actions
    }

    private func files() -> [StackedDiffFile] {
      [
        StackedDiffFile(diff: WorkspaceSamples.mainDiff),
        StackedDiffFile(diff: WorkspaceSamples.libDiff),
      ]
    }

    private func state(find: PullRequestFindState? = PullRequestFindState())
      -> PullRequestChangesState
    {
      var state = PullRequestChangesState()
      state.showsFileControls = true
      state.find = find
      state.offersCommits = true
      state.progress = PullRequestViewedProgress(
        viewed: 1, total: 2, partial: true, hideViewed: false)
      state.treeFiles = files().map {
        PullRequestTreeFile(path: $0.path, kind: $0.kind, added: $0.added, removed: $0.removed)
      }
      state.body = .diff(StackedDiffContent(files: files()))
      return state
    }

    private func screen(_ state: PullRequestChangesState, calls: Calls, width: CGFloat = 900)
      -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(
        AnyView(PullRequestChangesView(state: state, actions: actions(calls))),
        width: width, height: 600)
    }

    @Test("Command-F opens find, as the web's Changes tab, and nothing else takes it")
    func commandFOpensFind() throws {
      let calls = Calls()
      let shown = screen(state(), calls: calls)
      defer { shown.close() }
      #expect(try shown.pressShortcut(keyCode: 3, characters: "f", modifiers: .command))
      #expect(calls.log == ["find true"])

      // The commit list has no find bar, so the shortcut stays with the app.
      var commits = state(find: nil)
      commits.body = .commits(PullRequestCommitsState())
      let list = screen(commits, calls: Calls())
      defer { list.close() }
      #expect(try !list.pressShortcut(keyCode: 3, characters: "f", modifiers: .command))
    }

    @Test("The open find bar counts matches, offers hidden ones, and steps with Return")
    func findBar() throws {
      let calls = Calls()
      var find = PullRequestFindState()
      find.isOpen = true
      find.query = "fn"
      find.status = "2 of 5"
      find.total = 5
      find.hidden = "+1 in hidden files"
      var open = state(find: find)
      open.offersFilter = false
      let shown = screen(open, calls: calls)
      defer { shown.close() }
      for text in ["2 of 5", "+1 in hidden files", "Show", "Aa", ".*"] {
        #expect(try shown.shows(text), "\(text)")
      }
      #expect(shown.firstTextField?.stringValue == "fn")
      try shown.typeIntoField("x")
      #expect(calls.log.contains("query fnx"))
      try shown.press(keyCode: 36, characters: "\r")
      #expect(calls.log.contains("step true"))
      try shown.press(keyCode: 53, characters: "\u{1B}")
      #expect(calls.log.contains("find false"))
    }

    @Test("The toolbar shows Changes or Commits, the viewed progress and Hide viewed")
    func toolbar() throws {
      let shown = screen(state(), calls: Calls())
      defer { shown.close() }
      for text in ["Changes", "Commits", "1 / 2 files viewed (partial)", "Hide viewed"] {
        #expect(try shown.shows(text), "\(text)")
      }
    }

    @Test("The file tree folds single-folder chains, folders first, and jumps to a file")
    func tree() throws {
      let built = PullRequestFileTree.build([
        PullRequestTreeFile(path: "omnigent/runner/x.py", kind: .modified, added: 1, removed: 0),
        PullRequestTreeFile(path: "README.md", kind: .added, added: 3, removed: nil),
        PullRequestTreeFile(path: "web/src/a.ts", kind: .deleted, added: nil, removed: 2),
        PullRequestTreeFile(path: "web/b.ts", kind: .renamed, added: 0, removed: 0),
      ])
      let names: [String] = built.map {
        switch $0 {
        case .file(let name, _): name
        case .folder(let name, _, _): name
        }
      }
      #expect(names == ["omnigent/runner", "web", "README.md"])
      guard case .folder(_, let path, let children) = built[1] else {
        Issue.record("web is a folder")
        return
      }
      #expect(path == "web")
      #expect(children.map(\.id) == ["d:web/src", "f:web/b.ts"])

      let calls = Calls()
      let shown = screen(state(), calls: calls)
      defer { shown.close() }
      #expect(try shown.shows("main.rs"))
      #expect(try shown.shows("+\(WorkspaceSamples.mainDiff.added)"))
    }

    @Test("The commit list searches by id, title and author, and opens a commit")
    func commitList() throws {
      let rows = [
        PullRequestCommitRow(
          sha: "aaaa1111bbbb", title: "Add parser", author: "Ann", date: nil, headOf: "Head of #41"),
        PullRequestCommitRow(
          sha: "cccc2222dddd", title: "Fix tests", author: "Bob", date: nil, headOf: nil),
      ]
      #expect(PullRequestCommitRow.filter(rows, query: "BOB").map(\.sha) == ["cccc2222dddd"])
      #expect(PullRequestCommitRow.filter(rows, query: "aaaa").count == 1)
      #expect(PullRequestCommitRow.filter(rows, query: " ").count == 2)

      var commits = PullRequestCommitsState()
      commits.commits = rows
      commits.hasMore = true
      var listed = state(find: nil)
      listed.body = .commits(commits)
      let calls = Calls()
      let shown = screen(listed, calls: calls)
      defer { shown.close() }
      for text in ["2 commits", "History limited to 250 commits", "Add parser", "aaaa111"] {
        #expect(try shown.shows(text), "\(text)")
      }
    }

    @Test("A file's header copies its path and opens it on the provider, or says why not")
    func fileActions() throws {
      var state = PullRequestFileActionsState(
        path: "src/new.rs", previousPath: "src/old.rs", openLabel: "Open in GitHub", openURL: nil,
        openUnavailable: "Revision unknown")
      state.offersViewed = true
      state.changedSinceViewed = true
      state.conversations = 2
      state.hasEarlierComments = true
      var log: [String] = []
      let shown = OffscreenWindow(
        AnyView(
          PullRequestFileActionsView(
            state: state, toggleEarlier: { log.append("earlier") },
            toggleViewed: { log.append("viewed") }
          )
          .padding()),
        width: 500, height: 200)
      defer { shown.close() }
      for text in ["Viewed", "Changed since viewed", "2"] {
        #expect(try shown.shows(text), "\(text)")
      }
      let menu = try shown.menu(at: 0)
      let titles = menu.items.map(\.title)
      #expect(titles.contains("Show earlier comments"))
      #expect(titles.contains("Copy previous path"))
      #expect(titles.contains("Open in GitHub"))
      #expect(menu.items.first { $0.title == "Open in GitHub" }?.isEnabled == false)
    }

    @Test("A local comment says where it is, that it is earlier, and offers edit to its author")
    func localComment() throws {
      let comment = PullRequestLocalCommentState(
        id: "c1",
        lineLabel: PullRequestLocalCommentState.lineLabel(old: false, start: 3, end: 5),
        earlier: true, addressed: false, body: "Rename this", canEdit: true)
      var actions = PullRequestLocalCommentActions()
      var deleted: [String] = []
      actions.edit = { _, _, done in done(true) }
      actions.delete = { deleted.append($0) }
      let shown = OffscreenWindow(
        AnyView(PullRequestLocalCommentsView(comments: [comment], actions: actions).padding()),
        width: 500, height: 200)
      defer { shown.close() }
      #expect(
        try shown.shows("Local comment \u{00B7} New lines 3\u{2013}5 \u{00B7} Earlier revision"))
      #expect(try shown.shows("Rename this"))
      // Edit, then Delete.
      try shown.clickControl(at: 1)
      #expect(deleted == ["c1"])
    }

    @Test("A composer chip names the file, the lines and the side")
    func composerChip() {
      let range = ComposerReviewComment.make(
        id: "c1", path: "src/a.rs", old: false, lines: 3...5, body: "x")
      #expect(range.label == "src/a.rs:3\u{2013}5 (new)")
      #expect(range.detail == "src/a.rs \u{00B7} New line 3\u{2013}5")
      let single = ComposerReviewComment.make(
        id: "c2", path: "a.rs", old: true, lines: 9...9, body: "y")
      #expect(single.label == "a.rs:9 (old)")
    }
  }
#endif
