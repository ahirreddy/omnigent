#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// Settings > Local Server: status, the CLI, startup options and logs.
  @MainActor
  @Suite("Local Server settings", .serialized)
  struct LocalServerSettingsTests {
    init() { DesktopSideEffects.reset() }

    private func hosted(_ fixture: DesktopFixture) -> OffscreenWindow<LocalServerSettingsView> {
      OffscreenWindow(LocalServerSettingsView(desktop: fixture.desktop), width: 580, height: 1200)
    }

    /// The switches, top to bottom: start on launch, restart, automatic port, menu bar.
    private func switches(
      _ screen: OffscreenWindow<LocalServerSettingsView>
    ) -> [CGRect] {
      screen.controlFrames.filter { $0.width < 40 && $0.height < 20 }
    }

    @Test("this edition's reason replaces the controls when it can't run processes")
    func unavailable() throws {
      let fixture = try DesktopFixture(capability: .unavailable(.disabled("Off by policy.")))
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Off by policy."))
      #expect(text.contains("Show Omnigent in the menu bar"))
      #expect(!text.contains("Data directory"))
      #expect(screen.controlFrames.count == 1, "only the menu bar switch")
      let before = fixture.desktop.localServerPreferences.showsMenuBarExtra
      try screen.click(screen.controlFrames[0])
      #expect(fixture.desktop.localServerPreferences.showsMenuBarExtra != before)
    }

    @Test("Start runs the server and says who started it; Stop stops it")
    func startStop() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.confirmOpenLocalServer = { _ in false }
      let url = try loopback(6767)
      fixture.local.runner.script(announces(6767))
      fixture.local.probe.answer(
        url, .ready(LocalServerManifest(manifestVersion: 1, serverVersion: "0.9.0")))
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("Not running"))
      try screen.click(screen.controlFrames[0])
      #expect(await settle(screen) { fixture.manager.server.endpoint?.url == url })
      await flush(screen)
      let text = try screen.allText()
      #expect(text.contains("Running at http://127.0.0.1:6767"))
      #expect(text.contains("Started by"))
      #expect(text.contains("0.9.0"))
      #expect(text.contains("Stop"))
      try screen.click(screen.controlFrames[0])
      #expect(await settle(screen) { fixture.manager.server.endpoint == nil })
    }

    @Test("Start Host needs a server to host for and says so")
    func hostWithoutServer() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      try screen.click(screen.controlFrames[1])
      await flush(screen)
      #expect(fixture.manager.host == .failed(.noServerForHost))
      #expect(try screen.allText().contains(LocalServerError.noServerForHost.message))
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }

    @Test("with this Mac's server running, Start Host connects without a question")
    func hostsOwnServer() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.confirmOpenLocalServer = { _ in false }
      let url = try await fixture.startServer()
      fixture.local.runner.script { $0.print("\u{2713} Connected as 'mac'.") }
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      let hostRow = try #require(screen.controlFrames.dropFirst().first)
      try screen.click(hostRow)
      #expect(await settle(screen) { fixture.manager.host == .connected(serverURL: url, .owned) })
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
      let stopHost = try #require(screen.controlFrames.dropFirst().first)
      try screen.click(stopHost)
      #expect(await settle(screen) { fixture.manager.host == .stopped })
      await fixture.manager.stopOwnedProcesses()
    }

    @Test("the footer tells the truth about when hosting asks")
    func hostingFooter() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("This Mac's own server hosts without asking"))
      #expect(text.contains("any other server asks first"))
      #expect(!text.contains("never hosts on its own"))
    }

    @Test("a missing command-line tool says so, and Refresh looks again")
    func missingCLI() async throws {
      let fixture = try DesktopFixture(executables: [])
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      #expect(await settle(screen) { (try? screen.allText().contains("Not found")) == true })
      guard case .missing(let error) = fixture.manager.cli else {
        Issue.record("expected the CLI to be missing, got \(fixture.manager.cli)")
        return
      }
      #expect(try screen.allText().contains(error.message))
      // Choose, then Refresh: Use Automatic is off while no path is chosen.
      let row = screen.controlFrames.filter { $0.minY > 200 && $0.minY < 400 }
      try screen.click(try #require(row.last))
      await flush(screen)
      #expect(try screen.allText().contains("Not found"))
    }

    @Test("Choose takes the tool's path, and Use Automatic goes back to looking")
    func chooseCLI() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = fixture.desktop.localServerPreferences
      let screen = hosted(fixture)
      defer { screen.close() }
      #expect(await settle(screen) { fixture.manager.cli.resolution != nil })
      await flush(screen)
      #expect(try screen.allText().contains(LocalServerHarness.cliPath))
      let choose = try #require(screen.controlFrames.first { $0.minY > 200 })

      SystemSideEffects.answer(panel: .cancel)
      try screen.click(choose)
      #expect(SystemSideEffects.record.panelCount == 1)
      #expect(preferences.cliPath == nil, "cancelling keeps Automatic")

      SystemSideEffects.answer(panel: .OK)
      DesktopSideEffects.state.panelURL = URL(filePath: LocalServerHarness.cliPath)
      try screen.click(choose)
      await flush(screen)
      #expect(preferences.cliPath == LocalServerHarness.cliPath)

      let useAutomatic = try #require(
        screen.controlFrames.first { $0.minY == choose.minY && $0.minX > choose.maxX })
      try screen.click(useAutomatic)
      await flush(screen)
      #expect(preferences.cliPath == nil)
    }

    @Test("the startup switches change their preferences")
    func startupSwitches() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = fixture.desktop.localServerPreferences
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      let startOnLaunch = preferences.startOnLaunch
      let restartOnCrash = preferences.restartOnCrash
      let showsExtra = preferences.showsMenuBarExtra
      let frames = switches(screen)
      try #require(frames.count == 4, "\(frames)")
      try screen.click(frames[0])
      #expect(preferences.startOnLaunch != startOnLaunch)
      try screen.click(frames[1])
      #expect(preferences.restartOnCrash != restartOnCrash)
      try screen.click(frames[3])
      #expect(preferences.showsMenuBarExtra != showsExtra)
    }

    @Test("a fixed port takes real ports and refuses ones that aren't")
    func fixedPort() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = fixture.desktop.localServerPreferences
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(preferences.port == nil)
      try screen.click(switches(screen)[2])
      await flush(screen)
      #expect(preferences.port == 6767)
      let field = try #require(
        screen.allViews.compactMap { $0 as? NSTextField }.first {
          $0.isEditable && $0.stringValue == "6767"
        })
      try screen.click(field)
      field.currentEditor()?.selectAll(nil)
      try screen.type("7000")
      try screen.press(keyCode: 36, characters: "\r")
      await flush(screen)
      #expect(preferences.port == 7000)
      field.currentEditor()?.selectAll(nil)
      try screen.type("70000")
      try screen.press(keyCode: 36, characters: "\r")
      await flush(screen)
      #expect(preferences.port == 7000, "not a port")
      try screen.click(switches(screen)[2])
      await flush(screen)
      #expect(preferences.port == nil, "automatic again")
    }

    @Test("the data directory can be chosen and put back")
    func dataDirectory() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = fixture.desktop.localServerPreferences
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      let row = screen.controlFrames.filter { $0.minY > 560 && $0.minY < 700 && $0.width > 60 }
      try #require(row.count == 2, "\(screen.controlFrames)")
      SystemSideEffects.answer(panel: .OK)
      let chosen = fixture.local.root.appending(path: "chosen")
      DesktopSideEffects.state.panelURL = chosen
      try screen.click(row[0])
      await flush(screen)
      #expect(preferences.dataDirectory == chosen.path)
      #expect(try screen.allText().contains(chosen.path))
      SystemSideEffects.answer(panel: .cancel)
      try screen.click(row[0])
      #expect(preferences.dataDirectory == chosen.path, "cancelling keeps it")
      try screen.click(row[1])
      await flush(screen)
      #expect(preferences.dataDirectory == nil)
    }

    @Test("Open Log Folder explains a folder that doesn't exist, else shows it in Finder")
    func logFolder() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      let open = try #require(screen.controlFrames.last)
      let folder = fixture.manager.serverLogDirectory
      try screen.click(open)
      await flush(screen)
      #expect(try screen.allText().contains("does not exist yet"))
      #expect(SystemSideEffects.record.revealedURLs.isEmpty)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try screen.click(open)
      await flush(screen)
      #expect(SystemSideEffects.record.revealedURLs == [folder])
      #expect(try !screen.allText().contains("does not exist yet"))
      // Opening the logs window goes through SwiftUI's scene action, which needs a running app.
      let showLogs = try #require(screen.controlFrames.dropLast().last)
      try screen.click(showLogs)
    }
  }

  /// Rows and states that aren't reachable by clicking: statuses as the manager reports them.
  @MainActor
  @Suite("Local service tones")
  struct LocalServiceToneTests {
    @Test("each status has a dot that matches how it's going")
    func tones() throws {
      let endpoint = try #require(LocalServerEndpoint(port: 6767, pid: 1, manifest: nil))
      #expect(LocalServerStatus.stopped.tone == .off)
      #expect(LocalServerStatus.checking.tone == .busy)
      #expect(LocalServerStatus.running(endpoint, .owned).tone == .good)
      #expect(LocalServerStatus.failed(.noServerForHost).tone == .bad)
      #expect(LocalHostStatus.stopped.tone == .off)
      #expect(LocalHostStatus.stopping.tone == .busy)
      #expect(LocalHostStatus.connected(serverURL: URL(filePath: "/"), .owned).tone == .good)
      #expect(LocalHostStatus.failed(.noServerForHost).tone == .bad)
    }
  }
#endif
