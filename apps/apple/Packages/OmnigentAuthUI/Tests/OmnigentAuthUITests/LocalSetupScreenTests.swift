#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  /// What the local setup screens show for each state of the CLI and the server.
  @MainActor
  @Suite("Local setup screens", .serialized)
  struct LocalSetupScreenTests {
    private func progress(
      _ state: LocalSetupState, spy: AuthSpy, canShowLogs: Bool = true
    ) -> LocalProgressView {
      LocalProgressView(
        state: state, actions: spy.setup(canShowLogs: canShowLogs),
        back: { spy.log.append("back") }, retry: { spy.log.append("retry") })
    }

    private func install(
      _ state: LocalSetupState, spy: AuthSpy, canInstall: Bool = true
    ) -> InstallCLIView {
      InstallCLIView(
        state: state, actions: spy.setup(canInstall: canInstall),
        back: { spy.log.append("back") }, start: { spy.log.append("started") })
    }

    @Test("a failed start says so with Try Again, the output and the logs")
    func failedStart() throws {
      let spy = AuthSpy()
      let state = LocalSetupState(
        cli: .found, server: .failed("Port 6767 is in use."), log: ["boot", "bind failed"])
      let screen = OffscreenWindow(progress(state, spy: spy), width: 620, height: 620)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Omnigent didn\u{2019}t start"))
      #expect(text.contains("Port 6767 is in use."))
      #expect(text.contains("bind failed"))
      try screen.clickFromEnd()
      #expect(spy.log == ["retry"])
      try screen.clickFromEnd(1)
      #expect(spy.log == ["retry", "back"])
      try screen.clickFromEnd(2)
      #expect(spy.log == ["retry", "back", "setup logs"])
    }

    @Test("a starting server says what it's doing and waits for output")
    func busyStart() throws {
      let spy = AuthSpy()
      let state = LocalSetupState(cli: .found, server: .busy("Migrating the database\u{2026}"))
      let screen = OffscreenWindow(
        progress(state, spy: spy, canShowLogs: false), width: 620, height: 620)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Migrating the database"))
      #expect(text.contains("Waiting for output"))
      #expect(!text.contains("Try Again"))
      #expect(!text.contains("Show Server Logs"))
    }

    @Test("new output joins the log")
    func logGrows() async throws {
      let spy = AuthSpy()
      let state = LocalSetupState(cli: .found, server: .stopped, log: ["one"])
      let screen = OffscreenWindow(progress(state, spy: spy), width: 620, height: 620)
      defer { screen.close() }
      screen.host.rootView = progress(
        LocalSetupState(cli: .found, server: .stopped, log: ["one", "two"]), spy: spy)
      await flush(screen)
      #expect(try screen.allText().contains("two"))
    }

    @Test("Installation Instructions opens the guide")
    func guide() async throws {
      let spy = AuthSpy()
      let state = LocalSetupState(cli: .missing("not found"), server: .stopped)
      let screen = OffscreenWindow(
        install(state, spy: spy).environment(\.openURL, spy.openURL), width: 620, height: 620)
      defer { screen.close() }
      let guide = try #require(screen.controlFrames.first)
      try screen.click(guide)
      await flush(screen)
      #expect(spy.opened == [LocalSetupActions.installGuideURL].compactMap(\.self))
    }

    @Test("Check Again reports what's still missing, and a found CLI moves on")
    func recheck() async throws {
      let spy = AuthSpy()
      let missing = LocalSetupState(cli: .missing("omnigent isn't on your PATH."), server: .stopped)
      let screen = OffscreenWindow(
        install(missing, spy: spy, canInstall: false), width: 620, height: 620)
      defer { screen.close() }
      #expect(try !screen.allText().contains("omnigent isn't on your PATH."))
      #expect(try screen.allText().contains("in a new Terminal window"))
      try screen.clickFromEnd()
      await flush(screen)
      #expect(spy.log == ["setup recheck"])
      #expect(try screen.allText().contains("omnigent isn't on your PATH."))
      screen.host.rootView = install(
        LocalSetupState(cli: .found, server: .stopped), spy: spy, canInstall: false)
      await flush(screen)
      #expect(spy.log == ["setup recheck", "started"])
    }

    @Test("a CLI that appears before the user checked doesn't jump ahead")
    func foundWithoutChecking() async throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        install(LocalSetupState(cli: .missing("x"), server: .stopped), spy: spy),
        width: 620, height: 620)
      defer { screen.close() }
      screen.host.rootView = install(LocalSetupState(cli: .found, server: .stopped), spy: spy)
      await flush(screen)
      #expect(spy.log.isEmpty)
    }

    @Test("Install runs from the app, and while it runs nothing else takes a click")
    func installs() async throws {
      let spy = AuthSpy()
      let missing = LocalSetupState(cli: .missing("x"), server: .stopped)
      let screen = OffscreenWindow(install(missing, spy: spy), width: 620, height: 620)
      defer { screen.close() }
      #expect(try screen.allText().contains("Install it here"))
      try screen.clickFromEnd()
      #expect(spy.log == ["setup install"])
      screen.host.rootView = install(
        LocalSetupState(cli: .missing("x"), server: .stopped, log: ["uv"], install: .installing),
        spy: spy)
      await flush(screen)
      let text = try screen.allText()
      #expect(text.contains("Installing uv and the Omnigent CLI."))
      #expect(text.contains("Installing\u{2026}"))
      #expect(text.contains("uv"))
      spy.log.removeAll()
      try screen.clickFromEnd()
      #expect(spy.log.isEmpty, "Install doesn't start twice")
    }

    @Test("a failed install shows why and its output")
    func installFails() throws {
      let spy = AuthSpy()
      let failed = LocalSetupState(
        cli: .missing("x"), server: .stopped, log: ["curl: 6"],
        install: .failed("uv couldn't be downloaded."))
      let screen = OffscreenWindow(install(failed, spy: spy), width: 620, height: 620)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("uv couldn't be downloaded."))
      #expect(text.contains("curl: 6"))
    }

    @Test("while the CLI is being looked for, Check Again says so and waits")
    func checking() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        install(LocalSetupState(cli: .checking, server: .stopped), spy: spy, canInstall: false),
        width: 620, height: 620)
      defer { screen.close() }
      #expect(try screen.allText().contains("Checking\u{2026}"))
      try screen.clickFromEnd()
      #expect(spy.log == ["back"], "the last control taking a click is Back")
    }
  }
#endif
