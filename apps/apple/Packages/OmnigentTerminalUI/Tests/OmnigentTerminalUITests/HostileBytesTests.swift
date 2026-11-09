import Foundation
import Testing

@testable import OmnigentTerminalUI

/// Remote output no terminal should crash on. No BEL (it beeps) and no OSC 52 (the clipboard).
private let escape = "\u{1b}"
private let terminator = "\u{1b}\\"

private let hostileSequences: [String] = [
  // Huge, reversed and absent parameters.
  "\(escape)[99999999999999999999;99999999999999999999H",
  "\(escape)[0;0H\(escape)[-1;-1H\(escape)[;;;;;;;;;;;;H",
  "\(escape)[99;1r\(escape)[1;99999r\(escape)[0;0r\(escape)[5;2r",
  "a\(escape)[999999999b",
  "\(escape)[999999999L\(escape)[999999999M\(escape)[999999999@\(escape)[999999999P",
  "\(escape)[999999999S\(escape)[999999999T\(escape)[999999999X\(escape)[999999999G",
  "\(escape)[999999999A\(escape)[999999999B\(escape)[999999999C\(escape)[999999999D",
  "\(escape)[" + String(repeating: "1;", count: 100_000) + "m",
  "\(escape)[38;2;999999;-1;xm\(escape)[48;5;99999m\(escape)[58:2::999:999:999m",
  // Modes: every private mode on and off, alternate screens nested, column switching.
  (0..<2_100).map { "\(escape)[?\($0)h" }.joined(),
  (0..<2_100).map { "\(escape)[?\($0)l" }.joined(),
  "\(escape)[?1049h\(escape)[?1049h\(escape)[?47h\(escape)[?1047h\(escape)[?1049l\(escape)[?1049l",
  "\(escape)[?40h\(escape)[?3h\(escape)[?3l\(escape)[?6h\(escape)[?69h\(escape)[99;1s",
  // Keyboard stacks pushed far past their depth, then popped past empty.
  String(repeating: "\(escape)[>1u", count: 1_000)
    + String(repeating: "\(escape)[<u", count: 2_000),
  // Titles: invalid UTF-8, empty, enormous, unterminated, then the terminator.
  "\(escape)]2;\u{FFFD}\(terminator)\(escape)]0;\(terminator)",
  "\(escape)]2;" + String(repeating: "T", count: 200_000) + terminator,
  "\(escape)]2;unterminated",
  terminator,
  // Hyperlinks, colors, notifications-free OSCs, working directories.
  "\(escape)]8;;\(String(repeating: "u", count: 100_000))\(terminator)link\(escape)]8;;\(terminator)",
  "\(escape)]8;id=;file:///etc/passwd\(terminator)x\(escape)]8;;\(terminator)",
  "\(escape)]4;999;rgb:zz/zz/zz\(terminator)\(escape)]10;?\(terminator)\(escape)]11;nonsense\(terminator)",
  "\(escape)]7;file://\(String(repeating: "h", count: 10_000))\(terminator)",
  "\(escape)]133;A\(terminator)\(escape)]133;Z;;;;\(terminator)\(escape)]999999999;x\(terminator)",
  // Device control, kitty graphics and private strings with bad payloads.
  "\(escape)P+q\(String(repeating: "F", count: 50_000))\(terminator)\(escape)P$q\(terminator)",
  "\(escape)_Ga=T,f=100,s=99999,v=99999;!!!!\(terminator)\(escape)_G\(terminator)",
  "\(escape)_Ga=p,i=4294967295,p=4294967295,c=999999,r=999999\(terminator)",
  "\(escape)_Ga=d,d=Z\(terminator)\(escape)^x\(terminator)\(escape)Xy\(terminator)",
  // Text at the margins: wide characters, stacked marks, right-to-left and NUL runs.
  "\(escape)[1;9999H" + String(repeating: "界", count: 2_000),
  "e" + String(repeating: "\u{0301}", count: 20_000),
  String(repeating: "👩‍👩‍👧‍👦", count: 2_000),
  "\u{202E}abc\u{202C}\u{200F}\u{FEFF}\u{FFFE}\u{FFFF}\u{10FFFF}",
  String(repeating: "\u{0}", count: 100_000),
  // Tabs, scrollback and resets inside everything else.
  "\(escape)[9999g\(escape)H\(escape)[99999I\(escape)[99999Z"
    + String(repeating: "\t", count: 10_000),
  String(repeating: "line\r\n", count: 50_000),
  "\(escape)c\(escape)[!p\(escape)[3J\(escape)[2J\(escape)#8\(escape)7\(escape)8",
  "\(escape)[>c\(escape)[c\(escape)[5n\(escape)[6n\(escape)[?6n\(escape)[18t\(escape)[8;9999;9999t",
  "\(escape)(0lqk\(escape)(B\(escape))0\u{E}x\u{F}\(escape)*A\(escape)+B",
]

@Suite("Hostile remote output", .serialized)
struct HostileBytesTests {
  @Test("every hostile sequence leaves a working terminal")
  func sequences() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    for (index, sequence) in hostileSequences.enumerated() {
      #expect(
        await surface.survives(Array(sequence.utf8), marker: "alive-\(index)"),
        "\(sequence.prefix(40))")
    }
  }

  @Test("sequences split across frames at every byte still parse")
  func splitFrames() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let bytes = Array("\(escape)[38;2;1;2;3m界e\u{0301}\(escape)]2;title\(terminator)👩‍👩‍👧‍👦".utf8)
    for byte in bytes {
      surface.controller.feed([byte])
      await Task.yield()
    }
    #expect(await eventually { surface.controller.title == "title" })
    #expect(await surface.survives([], marker: "after-split"))
  }

  @Test("a title with invalid UTF-8 is dropped, and the next one is taken")
  func invalidTitle() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let start = Array("\(escape)]2;".utf8)
    surface.controller.feed(start + [0x61, 0xFF, 0xC0, 0x62] + Array(terminator.utf8))
    #expect(await surface.survives([], marker: "after-invalid-title"))
    #expect(surface.controller.title == nil)
    surface.controller.feed(start + Array("valid".utf8) + Array(terminator.utf8))
    #expect(await eventually { surface.controller.title == "valid" })
  }

  @Test("random bytes leave a working terminal", arguments: [UInt64(1), 2, 3, 4])
  func randomBytes(seed: UInt64) async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    var generator = SeededGenerator(seed: seed)
    for _ in 0..<40 {
      var bytes = (0..<4_096).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
      for index in bytes.indices {
        if bytes[index] == 0x07 { bytes[index] = 0x20 }  // No bell.
        // No OSC.
        if bytes[index] == 0x5D, index > 0, bytes[index - 1] == 0x1B { bytes[index] = 0x5B }
      }
      surface.controller.feed(bytes)
      await Task.yield()
    }
    #expect(await surface.survives([], marker: "after-random-\(seed)"))
  }

  @Test("escape-heavy random text leaves a working terminal", arguments: [UInt64(11), 12])
  func randomSequences(seed: UInt64) async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    var generator = SeededGenerator(seed: seed)
    let finals = Array("ABCDEFGHJKLMPSTXZ@`abcdefghilmnpqrstuxz~")
    for _ in 0..<20_000 {
      let first = Int.random(in: 0...100_000, using: &generator)
      let second = Int.random(in: 0...3_000, using: &generator)
      let final = finals.randomElement(using: &generator) ?? "m"
      let prefix = Bool.random(using: &generator) ? "?" : ""
      surface.controller.feed(Array("\(escape)[\(prefix)\(first);\(second)\(final)x".utf8))
      await Task.yield()
    }
    #expect(await surface.survives([], marker: "after-sequences-\(seed)"))
  }

  @Test("a four-megabyte frame renders")
  func hugeFrame() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let frame = [UInt8](repeating: 0x61, count: 4_000_000)
    #expect(await surface.survives(frame, marker: "after-huge"))
  }

  @Test("mouse modes set by a program survive resizing and the demo TUI")
  func demoTUIResized() async throws {
    let surface = try NeverShownSurface(width: 900, height: 560)
    #expect(await surface.ready())
    let grid = try #require(surface.controller.gridSize)
    surface.connection.emit(
      Array(TerminalDemoContent.harnessTUI(columns: grid.columns, rows: grid.rows).utf8))
    #expect(await eventually { surface.controller.visibleText().contains("Harness TUI demo") })
    surface.controller.resize(points: CGSize(width: 1, height: 1), scale: 1)
    surface.controller.resize(points: CGSize(width: 900, height: 700), scale: 2)
    surface.connection.emit(Array(TerminalDemoContent.leaveHarnessTUI.utf8))
    #expect(await eventually { surface.controller.visibleText().contains("ready") })
  }

  @Test("a frame of many title changes leaves the main thread running")
  func frameOfManyTitles() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let frame = (0..<1_000).map { "\(escape)]2;title \($0)\(terminator)" }.joined()
    #expect(await surface.survives(Array(frame.utf8), marker: "after-titles"))
    #expect(await eventually { surface.controller.title == "title 999" })
  }

  @Test("frames of many titles, one after another, leave the main thread running")
  func framesOfManyTitles() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    for frame in 0..<20 {
      let titles = (0..<15).map { "\(escape)]2;title \(frame) \($0)\(terminator)" }.joined()
      surface.controller.feed(Array(titles.utf8))
    }
    #expect(await surface.survives(Array("x".utf8), marker: "after-frames"))
  }

  @Test("one sequence that sets many colors leaves the main thread running")
  func sequenceOfManyColors() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let colors = (0..<256).map { "\($0);rgb:11/22/33" }.joined(separator: ";")
    let frame = "\(escape)]4;\(colors)\(terminator)"
    #expect(await surface.survives(Array(frame.utf8), marker: "after-colors"))
    #expect(surface.controller.visibleText().contains("after-colors"))
    let resets = (0..<256).map { "\($0)" }.joined(separator: ";")
    let frame2 = "\(escape)]104;\(resets)\(terminator)"
    #expect(await surface.survives(Array(frame2.utf8), marker: "after-resets"))
  }

  @Test("a frame of many terminal queries leaves the main thread running")
  func frameOfManyQueries() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let frame = String(repeating: "\(escape)[6n\(escape)[c\(escape)]10;?\(terminator)", count: 500)
    #expect(await surface.survives(Array(frame.utf8), marker: "after-queries"))
  }

  @Test("a burst of frames with a title each is drained between frames")
  func burstOfTitleFrames() async throws {
    let connection = EchoTerminalConnection(prompt: "$ ", banner: "ready")
    for index in 0..<200 {
      connection.emit(Array("\(escape)]2;title \(index)\(terminator)".utf8))
    }
    let surface = try NeverShownSurface(connection: connection)
    #expect(await surface.ready())
    #expect(await eventually { surface.controller.title == "title 199" })
  }
}
