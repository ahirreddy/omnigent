import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI

  @testable import OmnigentUITestSupport
#endif

/// Switch Host's new sandboxes, as the web's: listed first, never the default while a host is
/// online, and a repository and branch in place of the directory.
@Suite("Switch Host into a new sandbox", .serialized)
@MainActor
struct HostMoveSandboxTests {
  private let rows = [
    HostMoveTarget(id: "old", name: "Old Mac", isOnline: true),
    HostMoveTarget(id: "lab", name: "Lab", isOnline: true),
    HostMoveTarget.sandbox("modal", name: "Modal Sandbox"),
  ]

  @Test("sandboxes come first, a host is still the default, and Resume lists none")
  func rules() {
    let kind = HostMoveKind.switchHost(currentHostID: "old")
    let targets = HostMoveRules.targets(rows, kind: kind, stranded: false)
    #expect(targets.map(\.id) == ["__sandbox__:modal", "lab"])
    #expect(HostMoveRules.defaultHost(targets, kind: kind) == "lab")
    let onlySandbox = HostMoveRules.targets(
      Array(rows.prefix(1)) + [rows[2]], kind: kind, stranded: false)
    #expect(HostMoveRules.defaultHost(onlySandbox, kind: kind) == "__sandbox__:modal")
    let resume = HostMoveRules.targets(
      rows, kind: .resume(preferredHostID: nil, workspace: nil), stranded: false)
    #expect(resume.map(\.id) == ["old", "lab"])
    #expect(
      HostMoveRules.description(kind, offersSandbox: true)
        == "Move this session to another connected machine or a new sandbox.")
    #expect(
      HostMoveRules.description(kind, offersSandbox: false)
        == "Move this session to another connected machine.")
  }

  #if os(macOS)
    private final class Log {
      var choices: [HostMoveChoice] = []
      var homes: [String] = []
    }

    private func screen(_ log: Log, outcome: HostMoveOutcome = .moved)
      -> OffscreenWindow<ComposerSheetHost<HostMoveSheet>>
    {
      let actions = HostMoveActions(
        loadHosts: { .success([HostMoveTarget.sandbox("modal", name: "Modal Sandbox")]) },
        home: {
          log.homes.append($0)
          return nil
        },
        browse: { _, _ in .failure(FolderBrowseError(message: "No")) },
        submit: {
          log.choices.append($0)
          return outcome
        },
        sandboxProblem: { repository, branch in
          repository.isEmpty && !branch.isEmpty
            ? HostMoveRepoProblem(
              isBranch: false, message: "Add the repository this branch belongs to.")
            : nil
        })
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: HostMoveSheet(kind: .switchHost(currentHostID: "old"), actions: actions) {}))
      _ = MainLoop.settle(until: { screen.window.attachedSheet != nil })
      return screen
    }

    @Test("a sandbox asks for a repository and branch, and moves with them")
    func movesWithRepository() async throws {
      let log = Log()
      let screen = screen(log)
      defer { screen.close() }
      await screen.drainTasks()
      #expect(try screen.shows("Move this session to another connected machine or a new sandbox."))
      #expect(try screen.shows("Files don\u{2019}t move into the sandbox."))
      #expect(log.homes.isEmpty, "a sandbox has no home to read")
      #expect(screen.fields.count == 2)
      try screen.type("https://github.com/org/repo", intoField: 0)
      try screen.type("main", intoField: 1)
      try screen.tapButton(fromEnd: 0)
      #expect(await screen.waitUntil { !log.choices.isEmpty }, "the move was chosen")
      var expected = HostMoveChoice(hostID: "__sandbox__:modal", workspace: "")
      expected.sandbox = HostMoveSandbox(
        provider: "modal", repository: "https://github.com/org/repo", branch: "main")
      #expect(log.choices == [expected])
    }

    @Test("a branch without a repository says so and can't be sent")
    func problem() async throws {
      let log = Log()
      let screen = screen(log)
      defer { screen.close() }
      await screen.drainTasks()
      try screen.type("main", intoField: 1)
      screen.settle()
      #expect(try screen.shows("Add the repository this branch belongs to."))
      try screen.tapButton(fromEnd: 0)
      await screen.drainTasks()
      #expect(log.choices.isEmpty)
    }

    @Test("an unconfirmed move says the session may not have moved")
    func unconfirmed() async throws {
      let log = Log()
      let screen = screen(log, outcome: .unconfirmed("Sandbox quota reached"))
      defer { screen.close() }
      await screen.drainTasks()
      try screen.tapButton(fromEnd: 0)
      #expect(await screen.waitUntil { !log.choices.isEmpty })
      screen.settle()
      #expect(try screen.shows("we could not confirm the move completed"))
      #expect(try screen.shows("Sandbox quota reached"))
    }
  #endif
}
