#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentRemoteBrowser

  /// Keys pressed in a window whose page was clicked: the window sends them to the view, which
  /// runs them through its input context.
  @MainActor
  @Suite("Remote browser view, typing in a window", .serialized)
  struct RemoteBrowserViewTypingTests {
    /// The page filling a window, in control.
    private func page(_ hosted: HostedStore) async -> OffscreenWindow<RemoteBrowserSurface> {
      await hosted.hostSends(HostedStore.snapshot())
      return OffscreenWindow(RemoteBrowserSurface(store: hosted.store), width: 1000, height: 500)
    }

    @Test("a click on the page reaches it in CSS pixels and gives it the keyboard")
    func clickFocuses() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let screen = await page(hosted)
      defer { screen.close() }
      let view = try #require(screen.allViews.compactMap { $0 as? RemoteBrowserView }.first)
      #expect(screen.window.firstResponder !== view)
      try screen.click(CGPoint(x: 300, y: 200))
      #expect(screen.window.firstResponder === view)
      let presses = hosted.connector.driver.mice.filter { $0.kind == .down || $0.kind == .up }
      #expect(presses.map(\.kind) == [.down, .up])
      #expect(presses.allSatisfy { abs($0.x - 300) < 1 && abs($0.y - 200) < 1 })
    }

    @Test("a typed letter reaches the page as a key down, its character and a key up")
    func typedLetter() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let screen = await page(hosted)
      defer { screen.close() }
      try screen.click(CGPoint(x: 300, y: 200))
      try screen.type("a")
      let keys = hosted.connector.driver.keys
      #expect(keys.map(\.kind) == [.rawKeyDown, .char, .keyUp])
      #expect(keys.map(\.text) == [nil, "a", nil])
      #expect(hosted.connector.driver.ime.isEmpty)
    }

    @Test("text the input context inserts whole, such as an emoji, reaches the page committed")
    func insertedText() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let screen = await page(hosted)
      defer { screen.close() }
      try screen.click(CGPoint(x: 300, y: 200))
      try screen.type("\u{1F600}")
      let sent = hosted.connector.driver.ime
      #expect(sent.map(\.op) == [.commit])
      #expect(sent.map(\.text) == ["\u{1F600}"])
      #expect(!hosted.connector.driver.keys.contains { $0.kind == .char })
    }

    @Test("before the page is clicked, typing in its window sends it nothing")
    func unfocusedTyping() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let screen = await page(hosted)
      defer { screen.close() }
      try screen.type("a")
      #expect(hosted.connector.driver.keys.isEmpty)
      #expect(hosted.connector.driver.ime.isEmpty)
    }
  }
#endif
