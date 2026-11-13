#if os(iOS)
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentRemoteBrowser

  @MainActor
  @Suite("Remote tab chrome on iPad, and the page menu", .serialized)
  struct RemotePadChromeTests {
    @Test("the iPad has one bar: history, the address, share and control; no bottom toolbar")
    func oneBar() async throws {
      let chrome = try await TouchChrome(
        TouchChrome.page(back: true, forward: false), tablet: true)
      defer { chrome.finish() }
      #expect(chrome.screen.shows("remote-browser.addressBar"))
      #expect(!chrome.screen.shows("remote-browser.toolbar"))
      #expect(!chrome.screen.shows("test.tabs"))
      #expect(chrome.screen.shows("remote-browser.share"))
      try await chrome.screen.activate("remote-browser.back")
      #expect(chrome.hosted.driverCalls.last == "nav back ")
      #expect(try !chrome.screen.isEnabled("remote-browser.forward"))
      try await chrome.screen.activate("remote-browser.handBack")
      #expect(chrome.hosted.driverCalls.last == "release")

      // Editing the address clears the bar of everything but the field and Cancel.
      try await chrome.screen.activate("remote-browser.address")
      await chrome.screen.settle(.milliseconds(450))
      #expect(!chrome.screen.shows("remote-browser.back"))
      #expect(!chrome.screen.shows("remote-browser.share"))
      try await chrome.screen.activate("remote-browser.address.cancel")
      await chrome.screen.settle(.milliseconds(450))
      #expect(chrome.screen.shows("remote-browser.back"))
    }

    @Test("on iPad the agent's request for the user shows under the bar")
    func handoff() async throws {
      let chrome = try await TouchChrome(
        TouchChrome.agent(handoff: "Solve a CAPTCHA"), tablet: true)
      defer { chrome.finish() }
      #expect(chrome.screen.labels.contains("Agent needs you: Solve a CAPTCHA"))
      // A scroll report while the agent drives leaves the iPad's bar alone.
      var scrolling = TouchChrome.agent(handoff: "Solve a CAPTCHA")
      scrolling.scroll = TouchChrome.scrolled(to: 300).scroll
      await chrome.hostSends(scrolling)
      try await chrome.screen.activate("remote-browser.handoff.takeOver")
      #expect(chrome.hosted.driverCalls.last == "take")
    }

    private func menuItems(
      _ hosted: HostedStore, presses: ChromePresses, sessions: Bool = true
    ) throws -> InProcessWindow {
      var showSessions: (@MainActor () -> Void)?
      if sessions { showSessions = { presses.sessions += 1 } }
      let items = RemotePageMenuItems(
        store: hosted.store, showSessions: showSessions, editingCustomSize: .constant(false))
      return try InProcessWindow(VStack { items })
    }

    @Test("the page menu shows the sessions, hands back, copies the link and resets the zoom")
    func pageMenu() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let presses = ChromePresses()
      let screen = try menuItems(hosted, presses: presses)
      defer { screen.close() }
      await hosted.hostSends(TouchChrome.page())
      await screen.settle()
      #expect(screen.labels.contains("You're in control"))
      #expect(screen.labels.contains("Profile: work"))
      try await screen.activate("remote-browser.menu.sessions")
      #expect(presses.sessions == 1)
      try await screen.activate("remote-browser.menu.handBack")
      #expect(hosted.driverCalls.last == "release")
      try await screen.activate("remote-browser.copyLink")
      let pasteboard = try #require(hosted.store.pasteboard as? MemoryPasteboard)
      #expect(pasteboard.text == "https://example.com/docs")

      #expect(!screen.shows("remote-browser.resetZoom"))
      hosted.store.zoomPercent = 250
      await screen.settle()
      #expect(screen.labels.contains("Reset Zoom (250%)"))
      try await screen.activate("remote-browser.resetZoom")
      #expect(hosted.store.zoomResets == 1)
      #expect(try !screen.isEnabled("remote-browser.viewport.mobileSite"))
    }

    @Test("while the agent drives, the page menu offers Take Over; a blank page has no link")
    func pageMenuWhileWatching() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let screen = try menuItems(hosted, presses: ChromePresses(), sessions: false)
      defer { screen.close() }
      var watching = TouchChrome.agent()
      watching.nav?.url = "about:blank"
      await hosted.hostSends(watching)
      await screen.settle()
      #expect(!screen.shows("remote-browser.menu.sessions"))
      #expect(!screen.shows("remote-browser.menu.handBack"))
      #expect(screen.labels.contains("Agent is browsing"))
      #expect(try !screen.isEnabled("remote-browser.copyLink"))
      try await screen.activate("remote-browser.menu.takeOver")
      #expect(hosted.driverCalls.last == "take")
    }

    @Test("in Mobile Size the page menu switches between mobile and desktop websites")
    func mobileSite() async throws {
      let hosted = HostedStore(mode: .mobile(site: false))
      defer { hosted.finish() }
      let screen = try menuItems(hosted, presses: ChromePresses())
      defer { screen.close() }
      await hosted.hostSends(TouchChrome.page())
      await screen.settle()
      #expect(screen.labels.contains("Request Mobile Website"))
      try await screen.activate("remote-browser.viewport.mobileSite")
      #expect(hosted.store.viewportMode == .mobile(site: true))
      #expect(screen.labels.contains("Request Desktop Website"))
      try await screen.activate("remote-browser.viewport.mobileSite")
      #expect(hosted.store.viewportMode == .mobile(site: false))
    }
  }
#endif
