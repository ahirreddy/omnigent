#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  /// A first run that joins a team: the server list and the question about where agents run.
  @MainActor
  @Suite("Onboarding joining", .serialized)
  struct OnboardingJoiningTests {
    @Test("Join your team opens the server list, and its Back returns to the landing")
    func joinTeam() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[1])
      await flush(screen)
      #expect(try screen.allText().contains("Server URL"))
      let back = try #require(screen.controlFrames.last)
      try screen.click(back)
      await flush(screen)
      #expect(try screen.allText().contains("Meet Omnigent"))
    }

    @Test("joining a remote server asks where agents run, then hosts here and connects")
    func runnerHostsHere() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[1])
      await flush(screen)
      try screen.fill(0, "https://team.example.com")
      try screen.pressReturn()
      await flush(screen)
      let text = try screen.allText()
      #expect(text.contains("Where do you work today?"))
      #expect(text.contains("team.example.com"))
      #expect(spy.log.isEmpty)
      try screen.clickFromEnd()
      #expect(
        spy.log == ["setup host https://team.example.com", "connect https://team.example.com"])
    }

    @Test("unticking This Mac joins without hosting")
    func runnerWithoutHosting() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[1])
      await flush(screen)
      try screen.fill(0, "https://team.example.com")
      try screen.pressReturn()
      await flush(screen)
      let toggle = try #require(screen.allViews.compactMap { $0 as? NSButton }.first)
      #expect(toggle.state == .on)
      try screen.click(toggle)
      await flush(screen)
      #expect(toggle.state == .off)
      try screen.clickFromEnd()
      #expect(spy.log == ["connect https://team.example.com"])
    }

    @Test(
      "without the CLI, where the app can install it, joining is Just join or Install CLI first")
    func joinChoiceWithoutCLI() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(local: OnboardingFixture.cliMissing, spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[1])
      await flush(screen)
      try screen.fill(0, "https://team.example.com")
      try screen.pressReturn()
      await flush(screen)
      let text = try screen.allText()
      #expect(text.contains("How do you want to join?"))
      #expect(text.contains("Just join") && text.contains("Install CLI first"))
      #expect(text.contains("Open Omnigent"), "Just join is the default")
      try screen.clickFromEnd()
      #expect(spy.log == ["connect https://team.example.com"], "Just join installs nothing")
    }

    @Test("installing first can be cancelled back to the choice, and joins once installed")
    func installFirst() async throws {
      let spy = AuthSpy()
      let server = "https://team.example.com"
      var state = OnboardingFixture.cliMissing
      state.install = .installing
      let installing = OffscreenWindow(
        OnboardingFlowView(
          step: .runnerInstall(serverUrl: server), directory: ServerDirectory(),
          localSetup: state, actions: spy.actions(localSetup: spy.setup())),
        width: 620, height: 820)
      defer { installing.close() }
      #expect(try installing.allText().contains("Installing the Omnigent CLI"))
      try installing.clickFromEnd()
      await flush(installing)
      #expect(try installing.allText().contains("How do you want to join?"), "Cancel goes back")
      #expect(spy.log.isEmpty, "Cancel neither joins nor hosts")

      state.install = .failed("uv could not be downloaded.")
      let failed = OffscreenWindow(
        OnboardingFlowView(
          step: .runnerInstall(serverUrl: server), directory: ServerDirectory(),
          localSetup: state, actions: spy.actions(localSetup: spy.setup())),
        width: 620, height: 820)
      defer { failed.close() }
      let text = try failed.allText()
      #expect(text.contains("Couldn\u{2019}t set up Omnigent") && text.contains("Continue Anyway"))
      try failed.clickFromEnd()
      try failed.clickFromEnd(1)
      #expect(spy.log == ["setup install", "connect \(server)"])

      let installed = OffscreenWindow(
        OnboardingFlowView(
          step: .runnerInstall(serverUrl: server), directory: ServerDirectory(),
          localSetup: OnboardingFixture.ready, actions: spy.actions(localSetup: spy.setup())),
        width: 620, height: 820)
      defer { installed.close() }
      await flush(installed)
      #expect(spy.log.suffix(2) == ["setup host \(server)", "connect \(server)"])
    }

    @Test("without the CLI the runner question can't host and explains how to later")
    func runnerWithoutCLI() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(
        local: OnboardingFixture.cliMissing, spy: spy, canInstall: false)
      defer { screen.close() }
      try screen.click(screen.landingButtons[1])
      await flush(screen)
      try screen.fill(0, "https://team.example.com")
      try screen.pressReturn()
      await flush(screen)
      #expect(try screen.allText().contains("Install the Omnigent CLI to run agents on this Mac"))
      try screen.clickFromEnd()
      #expect(spy.log == ["connect https://team.example.com"], "no hosting without the CLI")
    }

    @Test("Back from the runner question returns to the landing")
    func runnerBack() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[1])
      await flush(screen)
      try screen.fill(0, "https://team.example.com")
      try screen.pressReturn()
      await flush(screen)
      try screen.clickFromEnd(1)
      await flush(screen)
      #expect(try screen.allText().contains("Meet Omnigent"))
      #expect(spy.log.isEmpty)
    }

    @Test("the organization's first server leads the landing, its row as tall and wide as below")
    func organizationPreset() async throws {
      let spy = AuthSpy()
      let directory = ServerDirectory(managed: AuthSamples.directory.managed)
      let screen = OnboardingFixture.hosted(directory: directory, spy: spy)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Join your team (Acme Agents)"))
      #expect(text.contains("Other server\u{2026}"))
      let row = screen.presetRow
      let below = try #require(screen.landingButtons.last)
      #expect(row.count == 2, "the join button and its menu: \(row)")
      #expect(row.first?.minX.rounded() == below.minX.rounded(), "\(row), \(below)")
      #expect(row.last?.maxX.rounded() == below.maxX.rounded(), "\(row), \(below)")
      #expect(Set((row + [below]).map { $0.height.rounded() }).count == 1, "\(row), \(below)")
      try screen.click(try #require(row.first))
      await flush(screen)
      let question = try screen.allText()
      #expect(question.contains("Where do you work today?"))
      #expect(question.contains("Join Acme Agents"), "the server's own name, not its host")
    }

    @Test("the chevron beside the preset lists every organization server, and choosing one joins")
    func organizationChooser() async throws {
      let spy = AuthSpy()
      let directory = ServerDirectory(managed: AuthSamples.directory.managed)
      let screen = OnboardingFixture.hosted(directory: directory, local: nil, spy: spy)
      defer { screen.close() }
      SystemSideEffects.reset()
      defer { SystemSideEffects.reset() }
      let chooser = try #require(screen.presetRow.last)
      try screen.click(chooser)
      #expect(SystemSideEffects.record.poppedUpMenuCount == 1)
      #expect(spy.log.isEmpty, "a menu closed with no choice joins nothing")
      for server in ["Acme Agents", "staging.omnigent.corp.example.com"] {
        SystemSideEffects.chooseFromMenus(server)
        try screen.click(chooser)
        await flush(screen)
      }
      #expect(
        spy.log == [
          "connect https://omnigent.corp.example.com",
          "connect https://staging.omnigent.corp.example.com",
        ])
    }

    @Test("a single organization server is one full-width button, with no menu")
    func singleOrganizationServer() async throws {
      let spy = AuthSpy()
      let directory = ServerDirectory(managed: Array(AuthSamples.directory.managed.prefix(1)))
      let screen = OnboardingFixture.hosted(directory: directory, local: nil, spy: spy)
      defer { screen.close() }
      let row = screen.presetRow
      #expect(row.count == 1, "\(row)")
      #expect(row.first?.width.rounded() == screen.landingButtons.last?.width.rounded())
      let preset = try #require(row.first)
      try screen.click(CGPoint(x: preset.maxX - 8, y: preset.midY))
      await flush(screen)
      #expect(spy.log == ["connect https://omnigent.corp.example.com"])
    }

    @Test("a failed connect opens on the server list with the failure")
    func failureOpensServers() throws {
      let spy = AuthSpy()
      let failure = SignInError(category: .transport, message: "Couldn\u{2019}t reach the server.")
      let screen = OnboardingFixture.hosted(spy: spy, banner: .error(failure))
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Couldn\u{2019}t reach the server."))
      #expect(!text.contains("Meet Omnigent"))
    }
  }
#endif
