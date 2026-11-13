#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  extension OffscreenWindow {
    /// Presses Escape.
    func pressEscape() throws { try press(keyCode: 53, characters: "\u{1B}") }

    /// Presses Command-period, the Mac's other way to cancel.
    func pressCommandPeriod() throws {
      try press(keyCode: 47, characters: ".", modifiers: .command)
    }
  }

  /// A card's buttons by key, with no field holding the keyboard: Return is the primary button
  /// and Escape or Command-period the cancel button.
  @MainActor
  @Suite("Auth card keys", .serialized)
  struct AuthCardKeyTests {
    private func browserSignIn(_ spy: AuthSpy) -> OffscreenWindow<BrowserSignInView> {
      OffscreenWindow(
        BrowserSignInView(
          server: AuthSamples.oidcServer, option: .loopbackBrowser(path: "/cb"),
          alternatives: [.browserTicket], banner: nil, actions: spy.actions()),
        width: 560, height: 560)
    }

    private func connecting(_ spy: AuthSpy) -> OffscreenWindow<ConnectingView> {
      OffscreenWindow(
        ConnectingView(
          title: "Connecting\u{2026}", serverUrl: "https://agents.example.com",
          actions: spy.actions()),
        width: 560, height: 360)
    }

    @Test("Return presses the primary button: the browser screen starts its best option")
    func returnStartsSignIn() throws {
      let spy = AuthSpy()
      let screen = browserSignIn(spy)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(spy.browserOptions == [.loopbackBrowser(path: "/cb")])
      #expect(spy.log.isEmpty, "Return doesn't cancel")
    }

    @Test("Escape presses the cancel button beside a primary one, and starts nothing")
    func escapeCancelsSignIn() throws {
      let spy = AuthSpy()
      let screen = browserSignIn(spy)
      defer { screen.close() }
      try screen.pressEscape()
      #expect(spy.log == ["cancel"])
      #expect(spy.browserOptions.isEmpty)
    }

    @Test("Escape stops connecting, where Cancel is the only button")
    func escapeStopsConnecting() throws {
      let spy = AuthSpy()
      let screen = connecting(spy)
      defer { screen.close() }
      try screen.pressEscape()
      #expect(spy.log == ["cancel"])
    }

    @Test("Command-period stops connecting too")
    func commandPeriodStopsConnecting() throws {
      let spy = AuthSpy()
      let screen = connecting(spy)
      defer { screen.close() }
      try screen.pressCommandPeriod()
      #expect(spy.log == ["cancel"])
    }

    @Test("Return does nothing where the card has no primary button")
    func returnWithoutPrimary() throws {
      let spy = AuthSpy()
      let screen = connecting(spy)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(spy.log.isEmpty)
      #expect(spy.browserOptions.isEmpty)
    }
  }
#endif
