#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The sandbox chips: the repositories to clone, and the profile to launch with.
  @Suite("New session: sandbox options", .serialized)
  @MainActor
  struct NewSessionSandboxTests {
    @MainActor
    private final class Log {
      var repos: [[SandboxRepoChoice]] = []
      var loaded: [String] = []
      var urlProblem: (String) -> String? = { _ in nil }
      var branchProblem: (String) -> String? = { _ in nil }
    }

    private let log = Log()
    private static let app = "https://github.com/acme/app.git"
    private static let github = GithubRepoOption(
      fullName: "acme/app", cloneURL: app, defaultBranch: "main", isPrivate: false)
    private static let secret = GithubRepoOption(
      fullName: "acme/secret", cloneURL: "https://github.com/acme/secret.git", defaultBranch: nil,
      isPrivate: true)

    private var repositoryActions: SandboxRepositoriesActions {
      let log = log
      return SandboxRepositoriesActions(
        setRepos: { log.repos.append($0) },
        urlProblem: { url, _ in log.urlProblem(url) },
        branchProblem: { _, branch in log.branchProblem(branch) },
        repoName: { URL(string: $0)?.lastPathComponent ?? $0 },
        isSameRepo: { $0 == $1 },
        loadBranches: { log.loaded.append($0) })
    }

    private func editor(_ state: SandboxRepositoriesState) -> OffscreenWindow<some View> {
      let screen = OffscreenWindow(
        SandboxRepositoriesEditor(state: state, actions: repositoryActions)
          .frame(width: 500, height: 400, alignment: .top))
      screen.settle()
      return screen
    }

    // MARK: Repositories

    @Test("An empty editor explains itself, by how many repositories it can hold")
    func emptyEditor() throws {
      let one = editor(SandboxRepositoriesState())
      defer { one.close() }
      #expect(try one.shows("Cloned into the sandbox at startup as the working directory."))
      let many = editor(SandboxRepositoriesState(maxRepos: 3))
      defer { many.close() }
      #expect(try many.shows("Cloned into the sandbox at startup, side by side;"))
    }

    @Test("A typed URL is added with its button, trimmed, and the field clears")
    func addByButton() throws {
      let screen = editor(SandboxRepositoriesState())
      defer { screen.close() }
      try screen.type("  https://a.test/r.git ", intoField: 0)
      screen.settle(0.05)
      try screen.tapButton(fromEnd: 0)
      #expect(log.repos == [[SandboxRepoChoice(url: "https://a.test/r.git")]])
      #expect(screen.fields.first?.stringValue.isEmpty == true)
    }

    @Test("Return adds too; a bad or empty URL adds nothing and says why")
    func addByReturn() throws {
      log.urlProblem = { $0 == "bad" ? "That isn't a URL" : nil }
      let screen = editor(SandboxRepositoriesState())
      defer { screen.close() }
      try screen.type("", intoField: 0)
      try screen.press(keyCode: ComposerKey.returnKey, characters: "\r")
      #expect(log.repos.isEmpty)
      try screen.type("bad", intoField: 0)
      screen.settle(0.05)
      #expect(try screen.shows("That isn't a URL"))
      try screen.press(keyCode: ComposerKey.returnKey, characters: "\r")
      #expect(log.repos.isEmpty)
      screen.fields[0].currentEditor()?.selectAll(nil)
      try screen.type("https://a.test/r", intoField: 0)
      try screen.press(keyCode: ComposerKey.returnKey, characters: "\r")
      #expect(log.repos == [[SandboxRepoChoice(url: "https://a.test/r")]])
    }

    @Test("A typed repository's branch is a field, and Remove takes it out")
    func typedRow() throws {
      let url = "https://a.test/r.git"
      let screen = editor(
        SandboxRepositoriesState(
          repos: [SandboxRepoChoice(url: url)], maxRepos: 2, notes: [url: "Public"]))
      defer { screen.close() }
      #expect(try screen.shows("r.git"))
      #expect(try screen.shows("Public"))
      try screen.type("dev", intoField: 0)
      #expect(
        log.repos.last == [SandboxRepoChoice(url: url, branch: "d")]
          || log.repos.last?.first?.branch.hasPrefix("d") == true)
      // The row's field, then Remove, before the add controls.
      let remove = try #require(screen.buttons.dropFirst().first)
      try screen.click(screen.clickPoint(remove))
      #expect(log.repos.last?.isEmpty == true)
    }

    @Test("A GitHub repository's branches come from a menu, loaded when it appears")
    func githubBranches() throws {
      let screen = editor(
        SandboxRepositoriesState(
          repos: [SandboxRepoChoice(url: Self.app, branch: "dev")], maxRepos: 2,
          githubRepos: [Self.github, Self.secret], branches: ["acme/app": ["main", "dev", "bad"]]))
      defer { screen.close() }
      log.branchProblem = { $0 == "bad" ? "Not allowed" : nil }
      #expect(log.loaded == ["acme/app"])
      #expect(try screen.shows("acme/app"))
      #expect(try screen.shows("dev"))
      let menu = try screen.menu(at: 0)
      #expect(menuTitles(menu) == ["Default (main)", "dev", "bad"])
      try screen.choose("dev", in: menu)
      #expect(log.repos.last == [SandboxRepoChoice(url: Self.app, branch: "dev")])
      try screen.choose("Default (main)", in: menu)
      #expect(log.repos.last == [SandboxRepoChoice(url: Self.app)])
    }

    @Test("A branch that's still loading says so; with no default it's named plainly")
    func githubBranchesLoading() throws {
      let noDefault = GithubRepoOption(
        fullName: "acme/app", cloneURL: Self.app, defaultBranch: nil, isPrivate: false)
      let screen = editor(
        SandboxRepositoriesState(
          repos: [SandboxRepoChoice(url: Self.app)], githubRepos: [noDefault]))
      defer { screen.close() }
      #expect(try screen.shows("Default branch"))
      #expect(
        menuTitles(try screen.menu(at: 0)) == ["Default branch", "Loading branches\u{2026}"])
    }

    @Test("A branch problem shows on the row")
    func branchProblem() throws {
      log.branchProblem = { _ in "Branch not found" }
      let screen = editor(
        SandboxRepositoriesState(repos: [SandboxRepoChoice(url: "https://a.test/r", branch: "x")]))
      defer { screen.close() }
      #expect(try screen.shows("Branch not found"))
    }

    @Test("Your GitHub repositories can be added, without those already chosen")
    func githubAdd() throws {
      let screen = editor(
        SandboxRepositoriesState(
          repos: [SandboxRepoChoice(url: Self.app)], maxRepos: 3,
          githubRepos: [Self.github, Self.secret], githubTruncated: true))
      defer { screen.close() }
      #expect(try screen.shows("Showing your most recently pushed repositories."))
      // The chosen row's branch menu, then the repository menu.
      let menu = try screen.menu(at: 1)
      #expect(menuTitles(menu) == ["acme/secret"])
      try screen.choose("acme/secret", in: menu)
      #expect(
        log.repos.last == [
          SandboxRepoChoice(url: Self.app), SandboxRepoChoice(url: Self.secret.cloneURL),
        ])
    }

    @Test("A failed GitHub list says so and leaves the URL field")
    func githubError() throws {
      let screen = editor(SandboxRepositoriesState(githubError: "401"))
      defer { screen.close() }
      #expect(try screen.shows("Couldn't load your GitHub repositories (401)."))
      #expect(screen.fields.count == 1)
    }

    @Test("At the limit there's nothing to add; over it the problem shows")
    func limits() throws {
      let one = SandboxRepoChoice(url: "https://a.test/one")
      let full = editor(SandboxRepositoriesState(repos: [one]))
      defer { full.close() }
      #expect(try !full.shows("https://github.com/org/repo"))

      let over = editor(
        SandboxRepositoriesState(
          repos: [one, SandboxRepoChoice(url: "https://a.test/two")], problem: "Only one allowed"))
      defer { over.close() }
      #expect(try over.shows("Only one allowed"))
    }

    @Test("The repository chip names what's chosen and opens the editor")
    func repositoryChip() throws {
      for (repos, label) in [
        ([SandboxRepoChoice](), "No repository"),
        ([SandboxRepoChoice(url: "https://a.test/one")], "one"),
        (
          [
            SandboxRepoChoice(url: "https://a.test/one"),
            SandboxRepoChoice(url: "https://a.test/two"),
          ],
          "2 repositories"
        ),
      ] {
        var actions = NewSessionOptionActions()
        actions.repositories = repositoryActions
        let options = NewSessionOptions(
          isSandbox: true, repositories: SandboxRepositoriesState(repos: repos))
        let screen = OffscreenWindow(
          NewSessionOptionsBar(options: options, actions: actions)
            .frame(width: 800, height: 200, alignment: .top))
        defer { screen.close() }
        screen.settle()
        #expect(try screen.shows(label))
        try screen.tapButton(0)
        screen.settle(0.2)
        #expect(screen.popoverWindow != nil)
      }
    }
  }

  extension OffscreenWindow {
    /// The popover this window opened. Events don't reach it, but what it shows can be read.
    var popoverWindow: NSWindow? {
      NSApp.windows.first { candidate in
        candidate.isVisible && String(describing: Swift.type(of: candidate)).contains("Popover")
          && candidate.parent == window
      }
    }

    /// The text fields in the open popover, top to bottom.
    var popoverFieldValues: [String] {
      guard let root = popoverWindow?.contentView else { return [] }
      var fields: [NSTextField] = []
      var pending: [NSView] = [root]
      while let view = pending.popLast() {
        if let field = view as? NSTextField, field.isEditable { fields.append(field) }
        pending.append(contentsOf: view.subviews)
      }
      return
        fields
        .sorted { $0.convert($0.bounds, to: root).minY < $1.convert($1.bounds, to: root).minY }
        .map(\.stringValue)
    }
  }
#endif
