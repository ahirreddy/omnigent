#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Browse Folders in the Switch Host sheet: a sheet over the sheet, whose choice fills the field.
  @Suite("Composer: choosing a folder for a host move", .serialized)
  @MainActor
  struct ComposerGapsHostMoveTests {
    private final class Log {
      var choices: [HostMoveChoice] = []
      var closes = 0
      /// Holds a move in flight until a test lets it finish.
      var pendingMove: CheckedContinuation<HostMoveOutcome, Never>?
    }
    private let log = Log()

    private func actions() -> HostMoveActions {
      let log = log
      return HostMoveActions(
        loadHosts: {
          .success([
            HostMoveTarget(id: "old", name: "Old Mac", isOnline: true),
            HostMoveTarget(id: "new", name: "New Mac", isOnline: true),
          ])
        },
        home: { _ in "/Users/me" },
        browse: { _, _ in
          .success(FolderListing(path: "/srv/project", parent: "/srv", folders: []))
        },
        submit: {
          log.choices.append($0)
          return .moved
        })
    }

    @Test("The folder chosen in Browse is where the session moves")
    func choosesFolder() async throws {
      let screen = OffscreenWindow(
        ComposerSheetHost(
          sheet: HostMoveSheet(kind: .switchHost(currentHostID: "old"), actions: actions()) {}))
      defer { screen.close() }
      screen.settle(0.5)
      await screen.drainTasks()
      // The icon-only Browse button sits before Cancel and Switch Host.
      try screen.tapButton(fromEnd: 2)
      let isBrowserUp = try await screen.eventually { screen.activeWindow.attachedSheet != nil }
      #expect(isBrowserUp)
      await screen.drainTasks()
      // A sheet over the sheet is out of the window helper's reach; Return is its Choose.
      let browser = try #require(screen.activeWindow.attachedSheet)
      let returnKey = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: browser.windowNumber, context: nil, characters: "\r",
          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: ComposerKey.returnKey))
      #expect(browser.performKeyEquivalent(with: returnKey))
      #expect(try await screen.eventually { screen.activeWindow.attachedSheet == nil })
      try screen.tapButton(fromEnd: 0)
      await screen.drainTasks()
      #expect(log.choices == [HostMoveChoice(hostID: "new", workspace: "/srv/project")])
    }
  }
#endif
