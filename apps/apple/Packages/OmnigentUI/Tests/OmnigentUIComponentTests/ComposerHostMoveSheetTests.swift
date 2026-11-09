#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Switch Host and Resume on a Machine, shown as sheets so their toolbar's Cancel and confirm
  /// buttons exist: those are the last two buttons.
  @Suite("Composer: move a session to another host", .serialized)
  @MainActor
  struct ComposerHostMoveSheetTests {
    private final class Log {
      var choices: [HostMoveChoice] = []
      var closes = 0
      var browsed: [String] = []
      var homes: [String] = []
    }
    private let log = Log()
    private static let hosts = [
      HostMoveTarget(id: "old", name: "Old Mac", isOnline: true),
      HostMoveTarget(id: "new", name: "New Mac", isOnline: true),
      HostMoveTarget(id: "gone", name: "Gone", isOnline: false),
    ]

    private func actions(
      hosts: Result<[HostMoveTarget], FolderBrowseError> = .success(hosts),
      home: String? = "/Users/me", outcome: HostMoveOutcome = .moved
    ) -> HostMoveActions {
      let log = log
      return HostMoveActions(
        loadHosts: { hosts },
        home: {
          log.homes.append($0)
          return home
        },
        browse: { host, _ in
          log.browsed.append(host)
          return .failure(FolderBrowseError(message: "No"))
        },
        submit: {
          log.choices.append($0)
          return outcome
        })
    }

    private func sheet(
      _ kind: HostMoveKind, _ actions: HostMoveActions
    ) -> OffscreenWindow<ComposerSheetHost<HostMoveSheet>> {
      let log = log
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: HostMoveSheet(kind: kind, actions: actions) { log.closes += 1 }))
      screen.settle(0.5)
      return screen
    }

    @Test("Switch Host offers other online hosts and moves to the first, in its home")
    func switchHost() async throws {
      let screen = sheet(.switchHost(currentHostID: "old"), actions())
      defer { screen.close() }
      await screen.drainTasks()
      #expect(screen.window.attachedSheet != nil)
      try screen.tapButton(fromEnd: 0)
      await screen.drainTasks()
      #expect(log.choices == [HostMoveChoice(hostID: "new", workspace: "/Users/me")])
      #expect(log.closes == 1)
    }

    @Test("Cancel closes without moving")
    func cancel() async throws {
      let screen = sheet(.switchHost(currentHostID: "old"), actions())
      defer { screen.close() }
      await screen.drainTasks()
      try screen.tapButton(fromEnd: 1)
      #expect(log.closes == 1)
      #expect(log.choices.isEmpty)
    }

    @Test("a typed ~ path goes to the host expanded; a relative one can't be submitted")
    func typedDirectory() async throws {
      let screen = sheet(.switchHost(currentHostID: "old"), actions())
      defer { screen.close() }
      await screen.drainTasks()
      // Select the home it filled in, then type over it.
      let field = try #require(screen.fields.first)
      _ = screen.activeWindow.makeFirstResponder(field)
      field.currentEditor()?.selectAll(nil)
      try screen.type("relative")
      let confirm = try #require(screen.buttons.last)
      try screen.click(screen.clickPoint(confirm))
      await screen.drainTasks()
      #expect(log.choices.isEmpty, "not an absolute path")
      #expect(log.closes == 1, "the last button left is Cancel")
    }

    @Test("a failed move stays open with the reason; a stranded one offers the old host again")
    func failedAndStranded() async throws {
      let failed = sheet(.switchHost(currentHostID: "old"), actions(outcome: .failed("Denied")))
      defer { failed.close() }
      await failed.drainTasks()
      try failed.tapButton(fromEnd: 0)
      await failed.drainTasks()
      #expect(log.choices.count == 1)
      #expect(log.closes == 0)

      let stranded = sheet(
        .switchHost(currentHostID: "old"), actions(outcome: .stranded("Runner died")))
      defer { stranded.close() }
      await stranded.drainTasks()
      try stranded.tapButton(fromEnd: 0)
      await stranded.drainTasks()
      #expect(log.choices.count == 2)
      #expect(log.closes == 0)
    }

    @Test("Resume prefers the session's host and directory, and passes the worktree branch")
    func resume() async throws {
      let kind = HostMoveKind.resume(preferredHostID: "new", workspace: "/src/app")
      let screen = sheet(kind, actions())
      defer { screen.close() }
      await screen.drainTasks()
      // Directory, then Branch, and Base branch once a branch is typed.
      #expect(screen.fields.count == 2)
      try screen.type("feature", intoField: 1)
      screen.settle()
      #expect(screen.fields.count == 3)
      try screen.type("main", intoField: 2)
      try screen.tapButton(fromEnd: 0)
      await screen.drainTasks()
      var expected = HostMoveChoice(hostID: "new", workspace: "/src/app")
      expected.branch = "feature"
      expected.baseBranch = "main"
      #expect(log.choices == [expected])
    }

    @Test("Browse is offered for the chosen host")
    func browse() async throws {
      let screen = sheet(.switchHost(currentHostID: "old"), actions())
      defer { screen.close() }
      await screen.drainTasks()
      // The icon-only Browse button sits before Cancel and Switch Host.
      try screen.tapButton(fromEnd: 2)
      screen.settle(0.5)
      await screen.drainTasks()
      #expect(log.browsed == ["new"])
    }

    @Test("a failed host list, an empty one and the loading state each say so")
    func emptyStates() throws {
      let failed = OffscreenWindow(
        HostMoveSheet(
          kind: .resume(preferredHostID: nil, workspace: nil),
          actions: actions(hosts: .failure(FolderBrowseError(message: "Server down")))
        ) {})
      defer { failed.close() }
      failed.settle(0.2)
      #expect(try failed.shows("Server down"))

      let none = OffscreenWindow(
        HostMoveSheet(
          kind: .switchHost(currentHostID: "only"),
          actions: actions(hosts: .success([HostMoveTarget(id: "only", name: "O", isOnline: true)]))
        ) {})
      defer { none.close() }
      none.settle(0.2)
      #expect(try none.shows("No other hosts are online."))
      #expect(try none.shows("Move this session to another connected machine."))

      let offline = OffscreenWindow(
        HostMoveSheet(
          kind: .resume(preferredHostID: nil, workspace: nil),
          actions: actions(hosts: .success([]))
        ) {})
      defer { offline.close() }
      offline.settle(0.2)
      #expect(try offline.shows("None of your machines are online."))
    }

    @Test("the switch warning says files stay behind; the home fills in once it loads")
    func warningAndHome() async throws {
      let screen = OffscreenWindow(
        HostMoveSheet(kind: .switchHost(currentHostID: "old"), actions: actions()) {})
      defer { screen.close() }
      await screen.drainTasks()
      #expect(try screen.shows("Anything uncommitted stays on the old machine"))
      #expect(log.homes == ["new"])
      #expect(screen.fields.first?.stringValue == "/Users/me")
    }

    @Test("choosing another host reads its home and clears the path on a switch")
    func changeHost() async throws {
      let hosts = Self.hosts + [HostMoveTarget(id: "third", name: "Third", isOnline: true)]
      let screen = OffscreenWindow(
        HostMoveSheet(
          kind: .switchHost(currentHostID: "old"), actions: actions(hosts: .success(hosts))
        ) {})
      defer { screen.close() }
      await screen.drainTasks()
      #expect(screen.fields.first?.stringValue == "/Users/me")
      let picker = try screen.menu(at: 0)
      try screen.choose("Third", in: picker)
      await screen.drainTasks()
      #expect(log.homes == ["new", "third"])
    }
  }
#endif
