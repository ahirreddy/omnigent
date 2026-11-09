#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// The Server Logs window's content.
  @MainActor
  @Suite("Server logs", .serialized)
  struct LocalServerLogsViewTests {
    init() { DesktopSideEffects.reset() }

    private func hosted(_ fixture: DesktopFixture) -> OffscreenWindow<LocalServerLogsView> {
      OffscreenWindow(LocalServerLogsView(manager: fixture.manager), width: 800, height: 500)
    }

    /// The footer's buttons, left to right: Copy and Clear (while there's output), Open Log Folder.
    private func footerButtons(_ screen: OffscreenWindow<LocalServerLogsView>) -> [CGRect] {
      screen.controlFrames.filter { $0.minY > 400 }
    }

    private func segment(_ index: Int, in screen: OffscreenWindow<LocalServerLogsView>) throws {
      let picker = try #require(screen.allViews.compactMap { $0 as? NSSegmentedControl }.first)
      let frame = picker.convert(picker.bounds, to: screen.host)
      let width = frame.width / CGFloat(picker.segmentCount)
      try screen.click(CGPoint(x: frame.minX + width * (CGFloat(index) + 0.5), y: frame.midY))
    }

    @Test("an edition without a local server explains itself instead of showing logs")
    func unavailable() throws {
      let fixture = try DesktopFixture(capability: .unavailable(.appSandbox))
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("No Local Server"))
      #expect(text.contains("App Sandbox"))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("with no output it says what to expect, and Copy and Clear wait")
    func empty() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("No Output Yet"))
      #expect(text.contains("once the server starts"))
      #expect(footerButtons(screen).count == 1, "only Open Log Folder")
    }

    @Test("the picker switches between the server's and the host's output")
    func processes() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.manager.serverLog.appendEvent("server line")
      fixture.manager.hostLog.appendEvent("host line")
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("server line"))
      #expect(try !screen.allText().contains("host line"))
      try segment(1, in: screen)
      await flush(screen)
      #expect(try screen.allText().contains("host line"))
      #expect(try screen.allText().contains("Not hosting"), "the footer follows the process")
      try segment(0, in: screen)
      await flush(screen)
      #expect(try screen.allText().contains("Not running"))
    }

    @Test("Copy puts the log on the clipboard, and Clear empties it")
    func copyAndClear() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.manager.serverLog.appendEvent("server line")
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      let buttons = footerButtons(screen)
      try #require(buttons.count == 3, "\(screen.controlFrames)")
      try screen.click(buttons[0])
      #expect(
        SystemSideEffects.pasteboard.string(forType: .string)?.contains("server line") == true)
      try screen.click(buttons[1])
      await flush(screen)
      #expect(fixture.manager.serverLog.lines.isEmpty)
      #expect(try screen.allText().contains("No Output Yet"))
    }

    @Test("Open Log Folder says when there isn't one yet, in the footer")
    func logFolder() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      try screen.click(try #require(footerButtons(screen).last))
      await flush(screen)
      #expect(try screen.allText().contains("does not exist yet"))
      try FileManager.default.createDirectory(
        at: fixture.manager.serverLogDirectory, withIntermediateDirectories: true)
      try screen.click(try #require(footerButtons(screen).last))
      #expect(SystemSideEffects.record.revealedURLs == [fixture.manager.serverLogDirectory])
    }

    @Test("Follow can be turned off, and new lines still arrive")
    func follow() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      fixture.manager.serverLog.appendEvent("first")
      await flush(screen)
      let toggle = try #require(screen.allViews.compactMap { $0 as? NSButton }.first)
      #expect(toggle.state == .on)
      try screen.click(toggle)
      await flush(screen)
      #expect(toggle.state == .off)
      fixture.manager.serverLog.appendEvent("second")
      await flush(screen)
      #expect(try screen.allText().contains("second"))
    }

    @Test("a log past its capacity says how many earlier lines went, and a blank line still shows")
    func dropped() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let log = fixture.manager.serverLog
      for index in 0..<5_600 { log.appendEvent("line \(index)") }
      _ = log.append(LocalProcessOutput(.standardOutput, Data("\n".utf8)))
      #expect(log.droppedLineCount > 0)
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("earlier lines not kept"))
    }
  }
#endif
