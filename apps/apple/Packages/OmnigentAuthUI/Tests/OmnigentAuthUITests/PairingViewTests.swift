#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentAuthUI

  /// Settings › Phone and the confirmation before connecting to a scanned server.
  @MainActor
  @Suite("Pairing views", .serialized)
  struct PairingViewTests {
    private func hosted(_ servers: [String]) -> OffscreenWindow<PairingSettingsView> {
      OffscreenWindow(PairingSettingsView(servers: servers), width: 520, height: 620)
    }

    @Test("no servers says to connect first and draws no code")
    func noServers() throws {
      let screen = hosted([])
      defer { screen.close() }
      #expect(try screen.allText().contains("Connect to a server first."))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("a server shows its code and address, with no warning for a reachable one")
    func remote() throws {
      let screen = hosted(["https://team.example.com"])
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("https://team.example.com"))
      #expect(text.contains("Pair your iPhone"))
      #expect(!text.contains("only reachable from this Mac"))
    }

    @Test("a loopback server warns that a phone can't reach it")
    func loopback() throws {
      let screen = hosted(["http://127.0.0.1:6767"])
      defer { screen.close() }
      #expect(try screen.allText().contains("only reachable from this Mac"))
    }

    @Test("choosing another server changes the address and the warning")
    func choosing() async throws {
      let screen = hosted(["https://team.example.com", "http://localhost:6767"])
      defer { screen.close() }
      let picker = try #require(screen.allViews.compactMap { $0 as? NSPopUpButton }.first)
      let frame = picker.convert(picker.bounds, to: screen.host)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      #expect(menu.items.map(\.title) == ["team.example.com", "localhost:6767"])
      try screen.choose("localhost:6767", in: menu)
      await flush(screen)
      let text = try screen.allText()
      #expect(text.contains("http://localhost:6767"))
      #expect(text.contains("only reachable from this Mac"))
    }

    @Test("confirming names the host and URL, then connects or cancels")
    func confirmation() throws {
      var outcome: [String] = []
      let screen = OffscreenWindow(
        PairingConfirmationView(
          confirmation: PairingConfirmation(
            serverURL: "https://team.example.com/api", host: "team.example.com", isLoopback: false),
          connect: { outcome.append("connect") }, cancel: { outcome.append("cancel") }),
        width: 520, height: 480)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("team.example.com"))
      #expect(text.contains("https://team.example.com/api"))
      #expect(!text.contains("points to the device"))
      try screen.clickFromEnd()
      try screen.clickFromEnd(1)
      #expect(outcome == ["connect", "cancel"])
    }

    @Test("confirming a loopback server warns it may not reach the computer")
    func confirmationLoopback() throws {
      let screen = OffscreenWindow(
        PairingConfirmationView(
          confirmation: PairingConfirmation(
            serverURL: "http://localhost:6767", host: "localhost:6767", isLoopback: true),
          connect: {}, cancel: {}),
        width: 520, height: 480)
      defer { screen.close() }
      #expect(try screen.allText().contains("points to the device"))
    }

    @Test("the code draws, and an address too long for a code says it couldn't")
    func qrCode() throws {
      let screen = OffscreenWindow(
        PairingQRCodeView(code: PairingCode(serverURL: "https://team.example.com")),
        width: 240, height: 240)
      defer { screen.close() }
      #expect(try !screen.allText().contains("could not be drawn"))
      let longAddress = "https://team.example.com/" + String(repeating: "x", count: 5_000)
      let tooLong = OffscreenWindow(
        PairingQRCodeView(code: PairingCode(serverURL: longAddress)), width: 240, height: 240)
      defer { tooLong.close() }
      #expect(try tooLong.allText().contains("could not be drawn"))
    }
  }
#endif
