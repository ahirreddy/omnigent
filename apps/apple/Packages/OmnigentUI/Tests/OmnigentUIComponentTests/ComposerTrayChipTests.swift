#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Where the session runs, in the row under the pill, and the context ring.
  @Suite("Composer: host, folder, worktree and context", .serialized)
  @MainActor
  struct ComposerTrayChipTests {
    private let log = ComposerActionLog()

    @Test("the host chip groups hosts, keeps offline ones in a submenu and selects any of them")
    func hostMenu() throws {
      let hosts = ComposerHosts(
        hosts: [
          ComposerHost(id: "cloud", name: "Cloud box", kind: .cloud, isOnline: true),
          ComposerHost(id: "mac", name: "Mac", kind: .machine, isOnline: true),
          ComposerHost(id: "gone", name: "Gone", kind: .machine, isOnline: false),
        ], selectedID: "mac")
      let model = ComposerScreenModel(state: ComposerViewState(hosts: hosts))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let menu = try screen.chip(0)
      let titles = menuTitles(menu)
      #expect(titles.contains("Cloud"))
      #expect(titles.contains("My machines"))
      #expect(titles.contains("Offline hosts (1)"))
      try screen.choose("Cloud box", in: menu)
      try screen.choose("Gone", in: menu)
      try screen.choose("Connect new host\u{2026}", in: menu)
      #expect(log.events == ["host:cloud", "host:gone", "connectHost"])
    }

    @Test("a locked host names itself in the context line and has no chip")
    func lockedHost() throws {
      let hosts = ComposerHosts(
        hosts: PreviewData.hosts.hosts, selectedID: "host_mbp", isLocked: true)
      let model = ComposerScreenModel(state: ComposerViewState(hosts: hosts))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(screen.chips.isEmpty)
    }

    @Test("the folder menu lists recents and opens another; the worktree menu picks or clears")
    func folderAndWorktree() throws {
      let state = ComposerViewState(
        tray: ComposerTray(
          directory: "/src/universe", recentDirectories: ["/src/universe", "/src/omnigent"],
          worktree: "No worktree", worktrees: ["feature"]))
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let folder = try screen.chip(0)
      try screen.choose("/src/omnigent", in: folder)
      try screen.choose("Open folder\u{2026}", in: folder)
      let worktree = try screen.chip(1)
      try screen.choose("feature", in: worktree)
      try screen.choose("No worktree", in: worktree)
      #expect(
        log.events == [
          "directory:/src/omnigent", "openFolder", "worktree:feature", "worktree:none",
        ]
      )
    }

    @Test("a folder with no way to change it is a label; a worktree without a handler too")
    func folderAndWorktreeFixed() throws {
      var actions = log.actions
      actions.extras.selectDirectory = nil
      actions.extras.openFolder = nil
      actions.extras.selectWorktree = nil
      let state = ComposerViewState(
        tray: ComposerTray(directory: "/src/universe", worktree: "main", branch: "dev"))
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(model, actions)
      defer { screen.close() }
      #expect(screen.chips.isEmpty)
    }

    // MARK: Context ring

    @Test("the context ring's tooltip says the percent and, when known, the tokens")
    func contextHelp() {
      #expect(ComposerTrayView.contextHelp(0.38, tokens: nil) == "38% context used")
      #expect(
        ComposerTrayView.contextHelp(0.38, tokens: ContextTokens(used: 76_000, window: 200_000))
          == "38% context used \u{00B7} 76K / 200K tokens")
      #expect(
        ComposerTrayView.contextHelp(1, tokens: ContextTokens(used: 1_500_000, window: 1_500_000))
          == "100% context used \u{00B7} 1.5M / 1.5M tokens")
    }

    @Test("the ring fills with use, in the footer and on touch's tray")
    func contextRing() throws {
      for style in [ComposerLayoutStyle.card, .touch] {
        let inks = try [0.0, 0.5, 1.0].map { fraction in
          var state = ComposerViewState(tray: ComposerTray(contextFraction: fraction))
          // Touch's bar shows the tray open on a new session.
          state.purpose = .start
          let view = ComposerView(draft: .constant(""), state: state, actions: log.actions)
            .environment(\.composerLayoutStyle, style)
          return try RenderSupport.render(
            view, width: 700, height: 200, scheme: .light, layout: .regular
          ).image.tiffRepresentation
        }
        #expect(inks[0] != inks[2], "\(style)")
        #expect(inks[1] != inks[2], "\(style)")
      }
    }
  }
#endif
