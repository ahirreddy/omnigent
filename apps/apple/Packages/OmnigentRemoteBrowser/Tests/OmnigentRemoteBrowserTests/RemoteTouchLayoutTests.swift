#if os(iOS)
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentRemoteBrowser

  @MainActor
  final class ChromePresses {
    var sessions = 0
    var tabs = 0
  }

  /// The remote tab as the app shows it on iPhone or iPad, with a test speaking as the host and
  /// pressing the chrome's buttons.
  @MainActor
  struct TouchChrome {
    let hosted = HostedStore()
    let presses = ChromePresses()
    let screen: InProcessWindow

    init(
      _ snapshot: RemoteBrowserSnapshot = Self.page(), tablet: Bool = false
    ) async throws {
      let presses = presses
      let tab = RemoteBrowserTabView(
        store: hosted.store, showSessions: { presses.sessions += 1 },
        tabsButton: {
          Button("Tabs") { presses.tabs += 1 }.accessibilityIdentifier("test.tabs")
        })
      screen = try InProcessWindow(
        tab, width: tablet ? 1024 : 393, height: tablet ? 768 : 852,
        horizontalSizeClass: tablet ? .regular : .compact)
      // The tab draws once as it is before the host says anything, as in the app.
      await screen.settle()
      await hostSends(snapshot)
    }

    func hostSends(_ snapshot: RemoteBrowserSnapshot) async {
      await hosted.hostSends(snapshot)
      await screen.settle()
    }

    func finish() {
      screen.close()
      hosted.finish()
    }

    /// A snapshot in control of a page at `url`.
    static func page(
      url: String = "https://example.com/docs", loading: Bool = false, progress: Double = 1,
      back: Bool = false, forward: Bool = false
    ) -> RemoteBrowserSnapshot {
      var snapshot = HostedStore.snapshot()
      snapshot.nav = RemoteBrowserNav(
        url: url, title: "Docs", loading: loading, progress: progress, canGoBack: back,
        canGoForward: forward, faviconUrl: nil)
      return snapshot
    }

    static func scrolled(to offset: Double) -> RemoteBrowserSnapshot {
      var snapshot = page()
      snapshot.scroll = RemoteScrollMetrics(
        x: 0, y: offset, contentWidth: 1000, contentHeight: 4000, viewportWidth: 1000,
        viewportHeight: 500)
      return snapshot
    }

    static func agent(handoff reason: String? = nil) -> RemoteBrowserSnapshot {
      var snapshot = page()
      snapshot.control = RemoteBrowserControl(
        owner: .agent, holder: .nobody, userId: nil,
        handoff: reason.map { RemoteBrowserHandoff(id: "handoff", reason: $0) })
      return snapshot
    }
  }

  @MainActor
  @Suite("Remote tab chrome on iPhone", .serialized)
  struct RemotePhoneChromeTests {
    @Test("the phone has an address pill on top and a toolbar at the bottom")
    func bars() async throws {
      let chrome = try await TouchChrome()
      defer { chrome.finish() }
      let shown = chrome.screen.identifiers
      for identifier in [
        "remote-browser.tab", "remote-browser.addressBar", "remote-browser.menu",
        "remote-browser.address", "remote-browser.reload", "remote-browser.toolbar",
        "remote-browser.back", "remote-browser.forward", "remote-browser.share",
        "remote-browser.handBack", "test.tabs", "remote-browser.surface",
      ] {
        #expect(shown.contains(identifier), "\(identifier) is missing")
      }
      #expect(
        try chrome.screen.element("remote-browser.address").accessibilityLabel
          == "Address, example.com")
      #expect(try !chrome.screen.isEnabled("remote-browser.back"))
      #expect(try !chrome.screen.isEnabled("remote-browser.forward"))
      #expect(try chrome.screen.isEnabled("remote-browser.share"))
      #expect(chrome.hosted.driverCalls.contains("visible true"))

      try await chrome.screen.activate("remote-browser.reload")
      #expect(chrome.hosted.driverCalls.last == "nav reload ")
      try await chrome.screen.activate("test.tabs")
      #expect(chrome.presses.tabs == 1)
    }

    @Test("back, forward and stop follow the page's history and loading")
    func navigation() async throws {
      let chrome = try await TouchChrome(
        TouchChrome.page(loading: true, progress: 0.4, back: true, forward: true))
      defer { chrome.finish() }
      try await chrome.screen.activate("remote-browser.back")
      #expect(chrome.hosted.driverCalls.last == "nav back ")
      try await chrome.screen.activate("remote-browser.forward")
      #expect(chrome.hosted.driverCalls.last == "nav forward ")
      #expect(!chrome.screen.shows("remote-browser.reload"))
      try await chrome.screen.activate("remote-browser.stop")
      #expect(chrome.hosted.driverCalls.last == "nav stop ")
      #expect(try chrome.screen.value(of: "remote-browser.progress") == "40%")
    }

    @Test("the control button hands back, takes over, or says who is driving")
    func control() async throws {
      let chrome = try await TouchChrome()
      defer { chrome.finish() }
      #expect(try chrome.screen.value(of: "remote-browser.handBack") == "You're in control")
      try await chrome.screen.activate("remote-browser.handBack")
      #expect(chrome.hosted.driverCalls.last == "release")

      await chrome.hostSends(TouchChrome.agent())
      #expect(!chrome.screen.shows("remote-browser.handBack"))
      #expect(try chrome.screen.value(of: "remote-browser.takeOver") == "Agent is browsing")
      try await chrome.screen.activate("remote-browser.takeOver")
      #expect(chrome.hosted.driverCalls.last == "take")

      var watching = TouchChrome.page()
      watching.connection = .attached(mode: .view)
      await chrome.hostSends(watching)
      #expect(try !chrome.screen.isEnabled("remote-browser.control"))
      #expect(
        try chrome.screen.value(of: "remote-browser.control") == "Viewing the agent's browser")
    }

    @Test("when the agent asks for the user a banner offers Take Over until it is dismissed")
    func handoff() async throws {
      let chrome = try await TouchChrome(TouchChrome.agent(handoff: "Sign in to continue"))
      defer { chrome.finish() }
      #expect(chrome.screen.shows("remote-browser.handoff"))
      #expect(chrome.screen.labels.contains("Agent needs you: Sign in to continue"))
      try await chrome.screen.activate("remote-browser.handoff.takeOver")
      #expect(chrome.hosted.driverCalls.last == "take")
      try await chrome.screen.activate("Dismiss")
      #expect(!chrome.screen.shows("remote-browser.handoff"))
      // The control button still offers it.
      #expect(chrome.screen.shows("remote-browser.takeOver"))
    }

    @Test("tapping the domain edits the whole address, without the toolbar; Cancel puts both back")
    func editingTheAddress() async throws {
      let chrome = try await TouchChrome()
      defer { chrome.finish() }
      try await chrome.screen.activate("remote-browser.address")
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.shows("remote-browser.address.cancel"))
      #expect(!chrome.screen.shows("remote-browser.toolbar"))
      #expect(!chrome.screen.shows("remote-browser.menu"))
      let field = try #require(chrome.screen.views(UITextField.self).first)
      #expect(field.text == "https://example.com/docs")

      try await chrome.screen.activate("remote-browser.address.clear")
      #expect(chrome.screen.views(UITextField.self).first?.text?.isEmpty == true)
      #expect(!chrome.screen.shows("remote-browser.address.clear"))

      try await chrome.screen.activate("remote-browser.address.cancel")
      await chrome.screen.settle(.milliseconds(450))
      #expect(!chrome.screen.shows("remote-browser.address.cancel"))
      #expect(chrome.screen.shows("remote-browser.toolbar"))
      #expect(chrome.screen.shows("remote-browser.menu"))
    }

    @Test("the field giving up the keyboard ends editing, as tapping the page does")
    func addressLosesFocus() async throws {
      let chrome = try await TouchChrome()
      defer { chrome.finish() }
      try await chrome.screen.activate("remote-browser.address")
      await chrome.screen.settle(.milliseconds(450))
      let field = try #require(chrome.screen.views(UITextField.self).first)
      #expect(field.isFirstResponder)
      #expect(field.resignFirstResponder())
      await chrome.screen.settle(.milliseconds(450))
      #expect(!chrome.screen.shows("remote-browser.address.cancel"))
      #expect(chrome.screen.shows("remote-browser.toolbar"))
    }

    @Test("a blank page offers a search field, nothing to share, and an empty address to edit")
    func blankPage() async throws {
      let chrome = try await TouchChrome(TouchChrome.page(url: "about:blank"))
      defer { chrome.finish() }
      #expect(chrome.screen.labels.contains("Search or enter website"))
      #expect(!chrome.screen.labels.contains("Secure"))
      #expect(try !chrome.screen.isEnabled("remote-browser.share"))
      try await chrome.screen.activate("remote-browser.address")
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.views(UITextField.self).first?.text?.isEmpty == true)
      #expect(!chrome.screen.shows("remote-browser.address.clear"))
    }

    @Test("scrolling down folds the bars to the domain; a tap, or a new page, unfolds them")
    func collapse() async throws {
      let chrome = try await TouchChrome(TouchChrome.scrolled(to: 0))
      defer { chrome.finish() }
      await chrome.hostSends(TouchChrome.scrolled(to: 60))
      await chrome.hostSends(TouchChrome.scrolled(to: 180))
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.shows("remote-browser.addressBar.collapsed"))
      #expect(!chrome.screen.shows("remote-browser.toolbar"))
      #expect(!chrome.screen.shows("remote-browser.addressBar"))

      try await chrome.screen.activate("remote-browser.addressBar.collapsed")
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.shows("remote-browser.toolbar"))
      #expect(chrome.screen.shows("remote-browser.addressBar"))

      await chrome.hostSends(TouchChrome.scrolled(to: 200))
      await chrome.hostSends(TouchChrome.scrolled(to: 300))
      await chrome.hostSends(TouchChrome.scrolled(to: 400))
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.shows("remote-browser.addressBar.collapsed"))
      var elsewhere = TouchChrome.scrolled(to: 400)
      elsewhere.nav?.url = "https://example.org/"
      await chrome.hostSends(elsewhere)
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.shows("remote-browser.addressBar"))
      #expect(
        try chrome.screen.element("remote-browser.address").accessibilityLabel
          == "Address, example.org")
    }

    @Test("the agent's own scrolling never folds the bars under the user")
    func agentScrolls() async throws {
      var watching = TouchChrome.scrolled(to: 0)
      watching.control = TouchChrome.agent().control
      let chrome = try await TouchChrome(watching)
      defer { chrome.finish() }
      watching.scroll?.y = 400
      await chrome.hostSends(watching)
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.shows("remote-browser.toolbar"))
      #expect(!chrome.screen.shows("remote-browser.addressBar.collapsed"))
    }

    @Test("the toolbar steps aside while the page's own field has the keyboard")
    func pageFieldFocused() async throws {
      let chrome = try await TouchChrome()
      defer { chrome.finish() }
      var typing = TouchChrome.page()
      typing.textInput.mode = .text
      await chrome.hostSends(typing)
      await chrome.screen.settle(.milliseconds(450))
      #expect(!chrome.screen.shows("remote-browser.toolbar"))
      #expect(chrome.screen.shows("remote-browser.addressBar"))
    }

    @Test("a notice the user can act on shows over the page")
    func notice() async throws {
      let chrome = try await TouchChrome()
      defer { chrome.finish() }
      #expect(!chrome.screen.shows("remote-browser.notice"))
      chrome.hosted.store.paste()
      await chrome.screen.settle()
      #expect(chrome.screen.shows("remote-browser.notice"))
      #expect(chrome.screen.labels.contains("The pasteboard has no text to paste."))
    }

    @Test("the bars read on the page's top colour: light content on a dark page, and back")
    func barColour() async throws {
      let chrome = try await TouchChrome()
      defer { chrome.finish() }
      func menuStyle() throws -> UIUserInterfaceStyle {
        try #require(chrome.screen.views(UIButton.self).first).traitCollection.userInterfaceStyle
      }
      #expect(try menuStyle() == .dark)
      chrome.hosted.store.edgeColor = RemoteEdgeColor(red: 1, green: 1, blue: 1)
      await chrome.screen.settle()
      #expect(try menuStyle() == .light)
      chrome.hosted.store.edgeColor = RemoteEdgeColor(red: 0, green: 0, blue: 0.1)
      await chrome.screen.settle()
      #expect(try menuStyle() == .dark)
    }
  }
#endif
