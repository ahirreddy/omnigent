#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  /// The connect form: a typed URL, the organization's servers and recent ones.
  @MainActor
  @Suite("Server picker", .serialized)
  struct ServerPickerTests {
    private static let localInstall = "http://127.0.0.1:\(LocalInstall.port)"
    private static let remote = "https://omnigent.example.com"

    private func picker(
      directory: ServerDirectory = ServerDirectory(), prefill: String = "",
      banner: AuthBanner? = nil, spy: AuthSpy, back: (() -> Void)? = nil,
      join: ((String) -> Void)? = nil, startLocal: (() -> Void)? = nil
    ) -> ServerPickerView {
      ServerPickerView(
        directory: directory, prefill: prefill, banner: banner, validator: .preview,
        actions: spy.actions(), localSetup: nil, back: back, join: join, startLocal: startLocal)
    }

    private func hosted(_ view: ServerPickerView) -> OffscreenWindow<ServerPickerView> {
      OffscreenWindow(view, width: 560, height: 820)
    }

    /// Waits for the recent rows' probes to answer.
    private func settledOnProbes(_ screen: OffscreenWindow<ServerPickerView>) async throws {
      let answered = await settle(screen) {
        (try? screen.allText().contains("Checking")) == false
      }
      #expect(answered)
    }

    @Test("Connect waits for a usable URL and joins the normalized one")
    func connects() throws {
      let spy = AuthSpy()
      let screen = hosted(picker(spy: spy))
      defer { screen.close() }
      let before = screen.controlFrames.count
      try screen.fill(0, "agents.example.com/")
      #expect(screen.controlFrames.count == before + 1, "Connect came on")
      #expect(try screen.allText().contains("Connects to https://agents.example.com"))
      try screen.clickFromEnd()
      #expect(spy.log == ["connect https://agents.example.com"])
    }

    @Test("Return in the field connects, and does nothing while it's empty")
    func returnKey() throws {
      let spy = AuthSpy()
      let screen = hosted(picker(spy: spy))
      defer { screen.close() }
      try screen.click(screen.fields[0])
      try screen.pressReturn()
      #expect(spy.log.isEmpty)
      try screen.type("https://agents.example.com")
      try screen.pressReturn()
      #expect(spy.log == ["connect https://agents.example.com"])
    }

    @Test("a rejected URL is flagged on submit, never connects, and the flag clears on editing")
    func rejected() throws {
      let spy = AuthSpy()
      let screen = hosted(picker(spy: spy))
      defer { screen.close() }
      let message = "This build requires https:// server URLs."
      try screen.fill(0, "http://plain.example.com")
      #expect(try !screen.allText().contains(message), "half-typed URLs aren't flagged")
      try screen.pressReturn()
      #expect(try screen.allText().contains(message))
      #expect(spy.log.isEmpty)
      try screen.type("m")
      #expect(try !screen.allText().contains(message))
    }

    @Test("the prefilled URL shows, and a new one from the store replaces it")
    func prefill() async throws {
      let spy = AuthSpy()
      let screen = hosted(picker(prefill: Self.remote, spy: spy))
      defer { screen.close() }
      #expect(screen.fields[0].stringValue == Self.remote)
      screen.host.rootView = picker(prefill: "https://other.example.com", spy: spy)
      await flush(screen)
      #expect(screen.fields[0].stringValue == "https://other.example.com")
    }

    @Test("organization servers are marked managed and connect on a click")
    func managed() throws {
      let spy = AuthSpy()
      let directory = ServerDirectory(managed: AuthSamples.directory.managed)
      let screen = hosted(picker(directory: directory, spy: spy))
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.localizedCaseInsensitiveContains("Provided by your organization"))
      #expect(text.contains("Managed"))
      #expect(text.contains("omnigent.corp.example.com"), "a named server shows its address")
      #expect(!text.contains("Your organization manages this list."))
      #expect(screen.serverRows.count == 2)
      try screen.click(screen.serverRows[0])
      #expect(spy.log == ["connect https://omnigent.corp.example.com"])
    }

    @Test("a forced list says who manages it, and its rows can't be forgotten")
    func forced() throws {
      let directory = ServerDirectory(
        managed: AuthSamples.directory.managed, serversAreForced: true)
      let screen = hosted(picker(directory: directory, spy: AuthSpy()))
      defer { screen.close() }
      #expect(try screen.allText().contains("Your organization manages this list."))
      #expect(try screen.contextMenuItems(screen.serverRows[0]).isEmpty)
    }

    @Test("recent servers say whether each answers, and the newest is marked last used")
    func recents() async throws {
      let spy = AuthSpy()
      spy.reachabilityByServer = [
        Self.remote: .omnigent(name: "Team Agents"), Self.localInstall: .unreachable,
        "https://gone.example.com": .unreachable, "https://web.example.com": .reachable,
      ]
      let directory = ServerDirectory(recentServers: [
        Self.remote, Self.localInstall, "https://gone.example.com", "https://web.example.com",
      ])
      let screen = hosted(picker(directory: directory, spy: spy))
      defer { screen.close() }
      try await settledOnProbes(screen)
      let text = try screen.allText()
      #expect(text.contains("Team Agents (omnigent.example.com)"))
      #expect(text.contains("Last used"))
      #expect(text.contains("Local installation (127.0.0.1:\(LocalInstall.port))"))
      #expect(text.contains("Not running"))
      #expect(text.contains("Can\u{2019}t reach"))
      #expect(text.contains("Reachable"))
      try screen.click(screen.serverRows[3])
      #expect(spy.log == ["connect https://web.example.com"])
      #expect(screen.fields[0].stringValue == "https://web.example.com")
    }

    @Test("picking the stopped local install starts it instead of failing to connect")
    func startsLocal() async throws {
      let spy = AuthSpy()
      spy.reachabilityByServer = [Self.localInstall: .unreachable]
      var started = 0
      let view = picker(
        directory: ServerDirectory(recentServers: [Self.localInstall]), spy: spy,
        startLocal: { started += 1 })
      let screen = hosted(view)
      defer { screen.close() }
      try await settledOnProbes(screen)
      try screen.click(screen.serverRows[0])
      #expect(started == 1)
      #expect(spy.log.isEmpty)
    }

    @Test("the local install connects directly while it's running")
    func connectsToRunningLocal() async throws {
      let spy = AuthSpy()
      spy.reachabilityByServer = [Self.localInstall: .omnigent(name: nil)]
      var started = 0
      let view = picker(
        directory: ServerDirectory(recentServers: [Self.localInstall]), spy: spy,
        startLocal: { started += 1 })
      let screen = hosted(view)
      defer { screen.close() }
      try await settledOnProbes(screen)
      #expect(try screen.allText().contains("Running"))
      try screen.click(screen.serverRows[0])
      #expect(started == 0)
      #expect(spy.log == ["connect \(Self.localInstall)"])
    }

    @Test("hovering a recent server reveals the button that forgets it")
    func forgetButton() async throws {
      let spy = AuthSpy()
      let directory = ServerDirectory(recentServers: [Self.remote, "https://two.example.com"])
      let screen = hosted(picker(directory: directory, spy: spy))
      defer { screen.close() }
      try await settledOnProbes(screen)
      let row = screen.serverRows[1]
      try screen.hover(CGPoint(x: row.midX, y: row.midY))
      await flush(screen)
      let forget = try #require(
        screen.controlFrames.first {
          $0.width < 40 && $0.midY > row.minY && $0.midY < row.maxY
        })
      try screen.click(forget)
      #expect(spy.log == ["forget https://two.example.com"], "the row itself didn't connect")
      try screen.endHover()
    }

    @Test("a recent server's context menu forgets it")
    func forgetMenu() async throws {
      let spy = AuthSpy()
      let screen = hosted(
        picker(directory: ServerDirectory(recentServers: [Self.remote]), spy: spy))
      defer { screen.close() }
      try await settledOnProbes(screen)
      let row = screen.serverRows[0]
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: row.midX, y: row.midY)))
      try screen.choose("Forget Server", in: menu)
      #expect(spy.log == ["forget \(Self.remote)"])
    }

    @Test("Back appears only when the flow has somewhere to go")
    func back() throws {
      var wentBack = 0
      let spy = AuthSpy()
      let screen = hosted(picker(spy: spy, back: { wentBack += 1 }))
      defer { screen.close() }
      try screen.clickFromEnd()
      #expect(wentBack == 1)
      let plain = hosted(picker(spy: spy))
      defer { plain.close() }
      #expect(plain.controlFrames.count == screen.controlFrames.count - 1)
    }

    @Test("a flow's join replaces connecting, for the question about where agents run")
    func join() throws {
      let spy = AuthSpy()
      var joined: [String] = []
      let screen = hosted(picker(spy: spy, join: { joined.append($0) }))
      defer { screen.close() }
      try screen.fill(0, Self.remote)
      try screen.pressReturn()
      #expect(joined == [Self.remote])
      #expect(spy.log.isEmpty)
    }

    @Test("a failed connect shows above the field and can be retried")
    func errorBanner() throws {
      let spy = AuthSpy()
      let failure = SignInError(
        category: .transport, message: "Couldn\u{2019}t reach the server.")
      let screen = hosted(picker(banner: .error(failure), spy: spy))
      defer { screen.close() }
      #expect(try screen.allText().contains("Couldn\u{2019}t reach the server."))
      let retry = try #require(screen.controlFrames.first)
      try screen.click(retry)
      #expect(spy.log == ["retry"])
    }

    @Test("a notice shows without a Retry")
    func notice() throws {
      let spy = AuthSpy()
      let screen = hosted(picker(banner: .notice("You\u{2019}re signed out."), spy: spy))
      defer { screen.close() }
      #expect(try screen.allText().contains("You\u{2019}re signed out."))
      let plain = hosted(picker(spy: spy))
      defer { plain.close() }
      #expect(screen.controlFrames.count == plain.controlFrames.count)
    }
  }

  extension OffscreenWindow {
    /// The titles of the context menu on a frame's middle; none when it has no menu.
    func contextMenuItems(_ frame: CGRect) throws -> [String] {
      try contextMenu(at: CGPoint(x: frame.midX, y: frame.midY))?.items.map(\.title) ?? []
    }
  }
#endif
