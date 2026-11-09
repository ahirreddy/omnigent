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

    @Test("without the CLI the runner question can't host and explains how to later")
    func runnerWithoutCLI() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(local: OnboardingFixture.cliMissing, spy: spy)
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

    @Test("the organization's server leads the landing and joins by name")
    func organizationPreset() async throws {
      let spy = AuthSpy()
      let directory = ServerDirectory(managed: AuthSamples.directory.managed)
      let screen = OnboardingFixture.hosted(directory: directory, spy: spy)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("Join your team (Acme Agents)"))
      #expect(text.contains("Other server\u{2026}"))
      try screen.click(screen.landingButtons[0])
      await flush(screen)
      let question = try screen.allText()
      #expect(question.contains("Where do you work today?"))
      #expect(question.contains("Join Acme Agents"), "the server's own name, not its host")
    }

    @Test("the chooser beside the preset lists the organization's servers")
    func organizationChooser() async throws {
      let spy = AuthSpy()
      let directory = ServerDirectory(managed: AuthSamples.directory.managed)
      let screen = OnboardingFixture.hosted(directory: directory, local: nil, spy: spy)
      defer { screen.close() }
      let chooser = try #require(
        screen.controlFrames.first { $0.width < 100 && $0.minY < 400 })
      let menu = try screen.openMenu(CGPoint(x: chooser.midX, y: chooser.midY))
      #expect(menu.items.map(\.title).contains("Acme Agents"))
      try screen.choose("staging.omnigent.corp.example.com", in: menu)
      await flush(screen)
      #expect(spy.log == ["connect https://staging.omnigent.corp.example.com"])
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
