#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  /// The flow hosted with a spy behind every action.
  @MainActor
  enum OnboardingFixture {
    static let ready = LocalSetupState(cli: .found, server: .stopped)
    static let cliMissing = LocalSetupState(
      cli: .missing("omnigent isn't on your PATH."), server: .stopped)

    static func hosted(
      directory: ServerDirectory = ServerDirectory(), local: LocalSetupState? = ready,
      spy: AuthSpy, banner: AuthBanner? = nil
    ) -> OffscreenWindow<some View> {
      let flow = OnboardingFlowView(
        directory: directory, prefill: "", banner: banner, localSetup: local, validator: .preview,
        actions: spy.actions(localSetup: spy.setup()))
      return OffscreenWindow(flow.environment(\.openURL, spy.openURL), width: 620, height: 820)
    }
  }

  extension OffscreenWindow {
    /// The landing's full-width buttons, top to bottom.
    var landingButtons: [CGRect] { controlFrames.filter { $0.width > 300 } }
  }

  /// A first run, clicked through: landing, local setup, joining a team.
  @MainActor
  @Suite("Onboarding flow", .serialized)
  struct OnboardingFlowTests {
    @Test("a new user sees the landing and starts locally")
    func startsLocally() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(spy: spy)
      defer { screen.close() }
      #expect(try screen.allText().contains("Meet Omnigent"))
      try screen.click(screen.landingButtons[0])
      await flush(screen)
      #expect(try screen.allText().contains("Set up Omnigent locally"))
      #expect(try screen.allText().contains("Start Omnigent"))
      try screen.clickFromEnd()
      await flush(screen)
      #expect(spy.log == ["setup start"])
      #expect(try screen.allText().contains("Starting Omnigent"))
    }

    @Test("Back walks from the local steps to the landing")
    func backToLanding() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[0])
      await flush(screen)
      try screen.clickFromEnd()
      await flush(screen)
      try screen.clickFromEnd()
      await flush(screen)
      #expect(try screen.allText().contains("Set up Omnigent locally"), "progress backs to intro")
      try screen.clickFromEnd(1)
      await flush(screen)
      #expect(try screen.allText().contains("Meet Omnigent"))
    }

    @Test("a running server offers Open, without the CLI step")
    func runningOffersOpen() async throws {
      let spy = AuthSpy()
      let running = LocalSetupState(cli: .found, server: .running(url: "http://127.0.0.1:6767"))
      let screen = OnboardingFixture.hosted(local: running, spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[0])
      await flush(screen)
      #expect(try screen.allText().contains("Open Omnigent"))
      try screen.clickFromEnd()
      await flush(screen)
      #expect(spy.log == ["setup start"])
      let text = try screen.allText()
      #expect(text.contains("Opening Omnigent"))
      #expect(text.contains("http://127.0.0.1:6767"))
    }

    @Test("without the CLI, setup goes to installing it, and Back returns to the intro")
    func needsCLI() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(local: OnboardingFixture.cliMissing, spy: spy)
      defer { screen.close() }
      try screen.click(screen.landingButtons[0])
      await flush(screen)
      #expect(try screen.allText().contains("Install Omnigent"))
      try screen.clickFromEnd()
      await flush(screen)
      #expect(try screen.allText().contains("Install the Omnigent CLI"))
      #expect(spy.log.isEmpty, "nothing starts without the CLI")
      try screen.clickFromEnd(2)
      await flush(screen)
      #expect(try screen.allText().contains("Set up Omnigent locally"))
    }

    @Test("once Check Again finds the CLI, the server starts on its own")
    func installedThenStarts() async throws {
      let spy = AuthSpy()
      let actions = spy.actions(localSetup: spy.setup(canInstall: false))
      let flow = { (local: LocalSetupState) in
        OnboardingFlowView(
          directory: ServerDirectory(), prefill: "", banner: nil, localSetup: local,
          validator: .preview, actions: actions)
      }
      let screen = OffscreenWindow(flow(OnboardingFixture.cliMissing), width: 620, height: 820)
      defer { screen.close() }
      try screen.click(screen.landingButtons[0])
      await flush(screen)
      try screen.clickFromEnd()
      await flush(screen)
      try screen.clickFromEnd()
      await flush(screen)
      #expect(spy.log == ["setup recheck"])
      screen.host.rootView = flow(OnboardingFixture.ready)
      await flush(screen)
      #expect(spy.log == ["setup recheck", "setup start"])
      #expect(try screen.allText().contains("Starting Omnigent"))
    }

    @Test("picking the stopped local install from the list starts it and shows its progress")
    func startsFromList() async throws {
      let spy = AuthSpy()
      let local = "http://127.0.0.1:\(LocalInstall.port)"
      spy.reachabilityByServer = [local: .unreachable]
      let screen = OnboardingFixture.hosted(
        directory: ServerDirectory(recentServers: [local]), spy: spy)
      defer { screen.close() }
      #expect(await settle(screen) { (try? screen.allText().contains("Not running")) == true })
      try screen.click(screen.serverRows[0])
      await flush(screen)
      #expect(spy.log == ["setup start"])
      #expect(try screen.allText().contains("Starting Omnigent"))
      try screen.clickFromEnd()
      await flush(screen)
      #expect(try screen.allText().contains("Set up Omnigent locally"))
    }

    @Test("the landing's links open in the browser")
    func links() async throws {
      let spy = AuthSpy()
      let screen = OnboardingFixture.hosted(spy: spy)
      defer { screen.close() }
      let linkFrames = screen.controlFrames.filter { $0.width < 200 }
      #expect(linkFrames.count == LandingLink.all.count)
      try screen.click(linkFrames[2])
      await flush(screen)
      #expect(spy.opened.map(\.absoluteString) == [LandingLink.all[2].url.absoluteString])
    }

    @Test("a screen for every state of the flow can be chosen")
    func startSteps() throws {
      let spy = AuthSpy()
      let screen = OffscreenWindow(
        OnboardingFlowView(
          step: .runner(serverUrl: "https://omnigent.corp.example.com"),
          directory: AuthSamples.directory, localSetup: OnboardingFixture.ready,
          actions: spy.actions(localSetup: spy.setup())),
        width: 620, height: 720)
      defer { screen.close() }
      #expect(try screen.allText().contains("Join Acme Agents"))
    }
  }
#endif
