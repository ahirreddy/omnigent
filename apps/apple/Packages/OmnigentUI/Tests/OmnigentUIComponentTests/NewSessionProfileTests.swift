#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The sandbox's profile list, and the form that names a new worktree's branch.
  @Suite("New session: profiles and branches", .serialized)
  @MainActor
  struct NewSessionProfileTests {
    @MainActor
    private final class Log {
      var selected: [String] = []
      var retries = 0
      var closes = 0
      var used: [NewSessionWorktreeChoice] = []
    }

    private let log = Log()

    // MARK: Profiles

    private func profile(_ name: String, detail: String = "") -> SandboxProfileOption {
      SandboxProfileOption(id: name, name: name, description: detail, revision: "1")
    }

    private func list(
      _ state: SandboxProfilesState,
      search: (@MainActor (String) async -> Result<[SandboxProfileOption], FolderBrowseError>)? =
        nil,
      retry: Bool = false
    ) -> OffscreenWindow<some View> {
      let log = log
      var retryAction: (@MainActor () -> Void)?
      if retry { retryAction = { log.retries += 1 } }
      let screen = OffscreenWindow(
        SandboxProfileList(
          state: state,
          actions: SandboxProfilesActions(
            select: { log.selected.append($0.name) }, search: search, retry: retryAction),
          close: { log.closes += 1 }
        ).frame(width: 320, height: 320))
      screen.settle()
      return screen
    }

    @Test("Each state of the chip reads as itself")
    func profileLabels() {
      #expect(SandboxProfilesState(selected: profile("A")).label == "A")
      #expect(SandboxProfilesState(isLoading: true).label == "Loading profiles\u{2026}")
      #expect(SandboxProfilesState(error: "x").label == "Profiles unavailable")
      #expect(SandboxProfilesState().label == "No profiles available")
      #expect(SandboxProfilesState(profiles: [profile("A")]).label == "Choose profile")
    }

    @Test("The chip opens the list")
    func profileChip() throws {
      let screen = OffscreenWindow(
        SandboxProfilePicker(
          state: SandboxProfilesState(selected: profile("Team")),
          actions: SandboxProfilesActions(select: { _ in })
        ).frame(width: 400, height: 200))
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("Team"))
      try screen.tapButton(0)
      screen.settle(0.2)
      #expect(screen.popoverWindow != nil)
    }

    @Test("Picking a profile selects it and closes")
    func profilePick() throws {
      let screen = list(
        SandboxProfilesState(profiles: [profile("One", detail: "The first"), profile("Two")]))
      defer { screen.close() }
      #expect(try screen.shows("The first"))
      try screen.tapButton(1)
      #expect(log.selected == ["Two"])
      #expect(log.closes == 1)
    }

    @Test("Loading, none, more than shown and failure each say so")
    func profileStates() throws {
      let loading = list(SandboxProfilesState(isLoading: true))
      defer { loading.close() }
      #expect(try loading.shows("Loading profiles\u{2026}"))

      let none = list(SandboxProfilesState())
      defer { none.close() }
      #expect(try none.shows("No sandbox profiles available for this provider."))

      let more = list(SandboxProfilesState(profiles: [profile("One")], hasMore: true))
      defer { more.close() }
      #expect(try more.shows("Showing the first profiles. Search to find others."))

      let failed = list(SandboxProfilesState(error: "Provider down"), retry: true)
      defer { failed.close() }
      #expect(try failed.shows("Provider down"))
      try failed.tapButton(fromEnd: 0)
      #expect(log.retries == 1)
    }

    @Test("Search shows what it finds, or that it found nothing, or why it failed")
    func profileSearch() async throws {
      let found = profile("Found")
      let screen = list(
        SandboxProfilesState(profiles: [profile("One")], error: "Stale"),
        search: { text in
          switch text {
          case "hit": .success([found])
          case "miss": .success([])
          default: .failure(FolderBrowseError(message: "Search failed"))
          }
        })
      defer { screen.close() }
      #expect(try screen.shows("Search profiles"))
      #expect(try screen.shows("Stale"))
      try screen.type("hit", intoField: 0)
      screen.settle(0.3)
      await screen.drainTasks()
      #expect(try screen.shows("Found"))
      #expect(try !screen.shows("One"))
      #expect(try !screen.shows("Stale"))
      try screen.tapButton(1)
      #expect(log.selected == ["Found"])

      screen.fields[0].currentEditor()?.selectAll(nil)
      try screen.type("miss", intoField: 0)
      screen.settle(0.3)
      await screen.drainTasks()
      #expect(try screen.shows("No matching profiles."))

      screen.fields[0].currentEditor()?.selectAll(nil)
      try screen.type("boom", intoField: 0)
      screen.settle(0.3)
      await screen.drainTasks()
      #expect(try screen.shows("Search failed"))
    }

    // MARK: Naming a branch

    private struct BranchHost: View {
      @State private var branch = ""
      @State private var base = ""
      let isValid: (@MainActor (String) -> Bool)?
      let use: @MainActor (NewSessionWorktreeChoice) -> Void
      let cancel: @MainActor () -> Void

      var body: some View {
        NewWorktreeBranchForm(
          branch: $branch, base: $base, isValidBranch: isValid, use: use, cancel: cancel)
      }
    }

    @Test("A new branch needs a valid name, and is sent trimmed from its base")
    func branchForm() throws {
      let log = log
      let screen = OffscreenWindow(
        BranchHost(
          isValid: { $0.hasPrefix("f") }, use: { log.used.append($0) }, cancel: {}
        ).frame(width: 400, height: 200))
      defer { screen.close() }
      screen.settle()
      try screen.type("nope", intoField: 0)
      screen.settle(0.05)
      let invalid = screen.buttons.count
      screen.fields[0].currentEditor()?.selectAll(nil)
      try screen.type(" fix ", intoField: 0)
      try screen.type(" dev ", intoField: 1)
      screen.settle(0.05)
      #expect(screen.buttons.count == invalid + 1)
      try screen.tapButton(fromEnd: 0)
      #expect(log.used == [.new(branch: "fix", base: "dev")])
    }

    @Test("With no validator any name will do; Cancel chooses nothing")
    func branchFormDefaults() throws {
      let log = log
      let screen = OffscreenWindow(
        BranchHost(
          isValid: nil, use: { log.used.append($0) }, cancel: { log.closes += 1 }
        ).frame(width: 400, height: 200))
      defer { screen.close() }
      screen.settle()
      // No name yet, so Use Branch isn't listed and Cancel is last.
      try screen.tapButton(fromEnd: 0)
      #expect(log.closes == 1)
      try screen.type("x", intoField: 0)
      screen.settle(0.05)
      _ = try screen.pressShortcut(keyCode: ComposerKey.returnKey, characters: "\r", modifiers: [])
      #expect(log.used == [.new(branch: "x", base: "")])
    }

    @Test("New Worktree opens the form on the current branch, or the default base")
    func branchFormOpens() throws {
      var options = NewSessionOptions(
        folder: "/a", offersWorktrees: true, defaultBaseBranch: " main ")
      var actions = NewSessionOptionActions()
      actions.selectWorktree = { _ in }
      let fresh = OffscreenWindow(
        NewSessionOptionsBar(options: options, actions: actions)
          .frame(width: 800, height: 200, alignment: .top))
      defer { fresh.close() }
      fresh.settle()
      try fresh.choose("New Worktree\u{2026}", in: try fresh.menu(at: 1))
      fresh.settle(0.2)
      #expect(fresh.popoverFieldValues == ["", "main"])

      options.worktree = .new(branch: "fix", base: "dev")
      let current = OffscreenWindow(
        NewSessionOptionsBar(options: options, actions: actions)
          .frame(width: 800, height: 200, alignment: .top))
      defer { current.close() }
      current.settle()
      try current.choose("New Worktree\u{2026}", in: try current.menu(at: 1))
      current.settle(0.2)
      #expect(current.popoverFieldValues == ["fix", "dev"])
    }
  }
#endif
