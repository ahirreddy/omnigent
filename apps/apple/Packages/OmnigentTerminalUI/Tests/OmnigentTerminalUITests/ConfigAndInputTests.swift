import CoreGraphics
import Testing

@testable import OmnigentTerminalUI

@Suite("Configuration and input mapping")
struct ConfigAndInputTests {
  @Test("the Ghostty configuration carries the appearance and the remote-terminal policy")
  func configText() {
    let appearance = TerminalAppearance(
      fontFamily: "Menlo", fontSize: 14.5, colorScheme: .light, scrollback: .small,
      optionAsAlt: false, cursorBlink: false)
    let text = GhosttyConfigText.make(appearance, systemFontFamily: "SF Mono")
    let lines = Set(text.split(separator: "\n").map(String.init))
    #expect(lines.contains("font-family = \"Menlo\""))
    #expect(lines.contains("font-size = 14.5"))
    #expect(lines.contains("background = #ffffff"))
    #expect(lines.contains("palette = 15=#18181b"))
    #expect(lines.contains("scrollback-limit = 2000000"))
    #expect(lines.contains("macos-option-as-alt = false"))
    #expect(lines.contains("cursor-style-blink = false"))
    #expect(lines.contains("clipboard-read = deny"))
    #expect(lines.contains("clipboard-write = deny"))
    #expect(lines.contains("shell-integration = none"))
    let system = GhosttyConfigText.make(TerminalAppearance(), systemFontFamily: "SF Mono")
    #expect(system.contains("font-family = \"SF Mono\""))
    #expect(system.contains("font-size = 13\n"))
    #expect(
      GhosttyConfigText.make(TerminalAppearance(), systemFontFamily: nil).contains("font-family")
        == false)
  }

  @Test("every generated configuration is accepted by libghostty")
  func configParses() throws {
    for scheme in TerminalColorScheme.allCases {
      for scrollback in TerminalScrollback.allCases {
        let appearance = TerminalAppearance(colorScheme: scheme, scrollback: scrollback)
        try GhosttyRuntime.validate(appearance)
      }
    }
  }

  @Test("the system font resolves to an installed family")
  func systemFont() throws {
    let family = try #require(TerminalFonts.systemFamily)
    #expect(TerminalFonts.isInstalled(family))
    #expect(!TerminalFonts.isInstalled(".AppleSystemUIFontMonospaced"))
  }

  @Test("HID usages map to the macOS keycodes libghostty expects")
  func hidKeyCodes() {
    #expect(HIDKeyCodes.macKeyCode[0x04] == 0x00)  // KeyA
    #expect(HIDKeyCodes.macKeyCode[0x06] == 0x08)  // KeyC
    #expect(HIDKeyCodes.macKeyCode[0x29] == 0x35)  // Escape
    #expect(HIDKeyCodes.macKeyCode[0x52] == 0x7E)  // ArrowUp
    for key in TerminalKey.allCases where key != .character {
      #expect(HIDKeyCodes.macKeyCode.values.contains(key.macKeyCode), "\(key)")
    }
  }

  @Test("grid sizes reject empty grids")
  func gridSize() {
    #expect(TerminalGridSize(columns: 0, rows: 10) == nil)
    #expect(TerminalGridSize(columns: 80, rows: 24)?.description == "80x24")
  }
}

@Suite("Fake connections")
struct FakeConnectionTests {
  @Test("the echo shell edits a line, runs it and drops input when read-only")
  func echoShell() async {
    let connection = EchoTerminalConnection(prompt: "$ ", banner: "hi")
    var output = connection.output.makeAsyncIterator()
    connection.start()
    #expect(connection.state == .attached(readOnly: false))
    #expect(await output.next() == .bytes(Array("\u{1b}[1;36mhi\u{1b}[0m\r\n$ ".utf8)))
    connection.send(Array("ab\u{7f}c\r".utf8))
    var echoed: [UInt8] = []
    for _ in 0..<7 {
      if case .bytes(let bytes) = await output.next() { echoed += bytes }
    }
    #expect(lossyUTF8(echoed) == "ab\u{8} \u{8}c\r\necho: ac\r\n$ ")

    let viewer = EchoTerminalConnection(readOnly: true)
    viewer.start()
    viewer.send(Array("x".utf8))
    #expect(viewer.state == .attached(readOnly: true))
    #expect(viewer.received == Array("x".utf8))
  }

  @Test("a malformed recording is reported with its line")
  func malformedRecording() {
    #expect(throws: ReplayTerminalConnection.RecordingError.self) {
      try ReplayTerminalConnection(
        jsonl: "{\"direction\":\"recv\",\"kind\":\"binary\",\"base64\":\"!\"}")
    }
  }

  @Test("the bundled REPL recording loads")
  func bundledRecording() throws {
    let replay = try ReplayTerminalConnection.recordedReplTUI()
    replay.start()
    #expect(replay.state == .attached(readOnly: true))
  }
}

@MainActor
@Suite("Surface pixel sizes")
struct SurfacePixelSizeTests {
  @Test("sizes round to whole pixels; empty, non-finite and huge sizes never trap")
  func pixelSizes() {
    #expect(TerminalSurfaceController.pixels(100.4, 2) == 201)
    #expect(TerminalSurfaceController.pixels(0, 2) == nil)
    #expect(TerminalSurfaceController.pixels(100, 0) == nil)
    #expect(TerminalSurfaceController.pixels(.infinity, 2) == nil)
    #expect(TerminalSurfaceController.pixels(.nan, 2) == nil)
    #expect(TerminalSurfaceController.pixels(1e12, 2) == UInt32.max)
  }
}
