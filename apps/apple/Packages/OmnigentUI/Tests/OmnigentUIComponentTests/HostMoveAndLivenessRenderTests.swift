#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Host move sheets and liveness row with hostile data", .serialized)
  struct HostMoveAndLivenessRenderTests {
    private static func actions(
      hosts: Result<[HostMoveTarget], FolderBrowseError>, home: String? = "/home/ahir"
    ) -> HostMoveActions {
      HostMoveActions(
        loadHosts: { hosts }, home: { _ in home },
        browse: { _, _ in .success(FolderListing(path: "/", parent: nil, folders: [])) },
        submit: { _ in .moved })
    }

    private static let realisticHosts = [
      HostMoveTarget(id: "here", name: "This Mac", isOnline: true),
      HostMoveTarget(id: "lab", name: "Lab", isOnline: true),
      HostMoveTarget(id: "old", name: "Old Mac", isOnline: false),
    ]

    private static var hostileHosts: [HostMoveTarget] {
      (0..<HostileData.rowCount).map {
        HostMoveTarget(id: "\($0)", name: HostileData.text($0), isOnline: $0 % 5 != 4)
      }
    }

    private static func notice(_ liveness: SessionLiveness, text: String = "sess_1")
      -> SessionLivenessNotice
    {
      SessionLivenessNotice(
        liveness: liveness, sessionID: text, serverURL: text, wrapper: text, harness: text)
    }

    private static func livenessActions(routes: Bool) -> SessionLivenessActions {
      var actions = SessionLivenessActions(checkAgain: {}, fork: {})
      if routes {
        actions.switchHost = HostMoveRoute(
          kind: .switchHost(currentHostID: "old"),
          actions: Self.actions(hosts: .success(realisticHosts)))
      }
      return actions
    }

    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("switch-host-realistic", realistic: true) {
        HostMoveSheet(
          kind: .switchHost(currentHostID: "old"),
          actions: actions(hosts: .success(realisticHosts)),
          close: {})
      },
      ScreenCase("resume-realistic", realistic: true, narrowOnly: true) {
        HostMoveSheet(
          kind: .resume(preferredHostID: "lab", workspace: "/Users/ahir/src"),
          actions: actions(hosts: .success(realisticHosts)), close: {})
      },
      ScreenCase("switch-host-no-targets", narrowOnly: true) {
        HostMoveSheet(
          kind: .switchHost(currentHostID: nil), actions: actions(hosts: .success([])), close: {})
      },
      ScreenCase("resume-load-failed", narrowOnly: true) {
        HostMoveSheet(
          kind: .resume(preferredHostID: nil, workspace: nil),
          actions: actions(hosts: .failure(FolderBrowseError(message: HostileData.unbroken))),
          close: {})
      },
      ScreenCase("switch-host-hostile") {
        HostMoveSheet(
          kind: .switchHost(currentHostID: HostileData.unbroken),
          actions: actions(hosts: .success(hostileHosts), home: HostileData.unbroken), close: {})
      },
      ScreenCase("resume-hostile", narrowOnly: true) {
        HostMoveSheet(
          kind: .resume(preferredHostID: "missing", workspace: HostileData.bidirectional),
          actions: actions(hosts: .success(hostileHosts), home: nil), close: {})
      },
      ScreenCase("liveness-asleep", height: nil, realistic: true) {
        SessionLivenessRow(notice: notice(.asleep), actions: livenessActions(routes: false))
      },
      // Draws nothing at all, so it gets a height: a zero-height view has no bitmap.
      ScreenCase("liveness-online-is-empty", height: 80, narrowOnly: true) {
        SessionLivenessRow(notice: notice(.online), actions: SessionLivenessActions())
      },
      ScreenCase("liveness-starting", height: nil, narrowOnly: true) {
        SessionLivenessRow(notice: notice(.starting), actions: SessionLivenessActions())
      },
      ScreenCase("liveness-host-offline", height: nil) {
        SessionLivenessRow(
          notice: notice(.hostOffline(isOwner: true)), actions: livenessActions(routes: true))
      },
      ScreenCase("reconnect-realistic", realistic: true) {
        ReconnectSessionSheet(
          notice: notice(.hostOffline(isOwner: true)), actions: livenessActions(routes: true),
          show: { _ in })
      },
      ScreenCase("reconnect-viewer-no-actions", narrowOnly: true) {
        ReconnectSessionSheet(
          notice: notice(.hostOffline(isOwner: false)), actions: SessionLivenessActions(),
          show: { _ in })
      },
      ScreenCase("reconnect-stranded-hostile") {
        ReconnectSessionSheet(
          notice: notice(.stranded, text: HostileData.unbroken),
          actions: livenessActions(routes: false), show: { _ in })
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }

    // Offscreen, hostChanged fires for "lab" but its Task never reaches actions.home.
    @Test("the sheet reads the hosts and the default host's home when it appears")
    func sheetLoadsOnAppear() async throws {
      var homesRead: [String] = []
      let loading = HostMoveActions(
        loadHosts: { .success(Self.realisticHosts) },
        home: { hostID in
          homesRead.append(hostID)
          return "/home/ahir"
        },
        browse: { _, _ in .failure(FolderBrowseError(message: "unused")) },
        submit: { _ in .moved })
      try await ViewSettler.settleLettingTasksRun(
        HostMoveSheet(kind: .switchHost(currentHostID: "here"), actions: loading, close: {}))
      #expect(homesRead == ["lab"], "the session's own host and offline hosts aren't offered")
    }
  }

  @Suite("Liveness notice and host paths with hostile input")
  struct HostileLivenessNoticeTests {
    @Test("a resume command quotes whatever the session and server are called")
    func quoting() {
      #expect(SessionLivenessNotice.quoted("") == "''", "an empty argument stays an argument")
      #expect(SessionLivenessNotice.quoted("sess_1-a.b/c:d") == "sess_1-a.b/c:d")
      #expect(SessionLivenessNotice.quoted("a b") == "'a b'")
      #expect(SessionLivenessNotice.quoted("it's; rm -rf ~") == "'it'\\''s; rm -rf ~'")
      #expect(SessionLivenessNotice.quoted("$(reboot)\n`x`") == "'$(reboot)\n`x`'")
      // CharacterSet.alphanumerics takes non-ASCII letters, which a shell passes through as is.
      #expect(SessionLivenessNotice.quoted("שלום") == "שלום")
    }

    @Test("only the unreachable states have a command, and a viewer's has none")
    func commands() {
      func command(_ liveness: SessionLiveness) -> String? {
        SessionLivenessNotice(
          liveness: liveness, sessionID: "s", serverURL: "https://x", wrapper: nil, harness: nil
        ).command
      }
      for liveness in [SessionLiveness.online, .starting, .asleep, .unknown] {
        #expect(command(liveness) == nil)
      }
      #expect(command(.hostOffline(isOwner: false)) == nil)
      #expect(command(.hostOffline(isOwner: true))?.contains("omnigent host") == true)
      #expect(command(.stranded)?.contains("omnigent run path/to/agent.yaml") == true)
    }

    @Test(
      "a typed directory that isn't absolute or home-relative has no path",
      arguments: ["", "   ", "relative/path", "~other/x", "\n", HostileData.bidirectional])
    func unresolved(typed: String) {
      #expect(HostMoveRules.resolvedWorkspace(typed, home: "/home/a") == nil)
    }

    @Test("slashes and blanks are trimmed, and / stays /")
    func trimmed() {
      #expect(HostMoveRules.resolvedWorkspace("////", home: nil) == "/")
      #expect(HostMoveRules.resolvedWorkspace("  /a/b///\n", home: nil) == "/a/b")
      #expect(HostMoveRules.resolvedWorkspace("~///", home: "/home/a///") == "/home/a")
      #expect(HostMoveRules.resolvedWorkspace("~/x", home: "/") == "/x")
      #expect(HostMoveRules.resolvedWorkspace("~", home: nil) == nil, "the home isn't known yet")
    }
  }
#endif
