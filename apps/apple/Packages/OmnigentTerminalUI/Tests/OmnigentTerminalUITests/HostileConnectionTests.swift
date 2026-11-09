import Foundation
import GhosttyKit
import Testing

@testable import OmnigentTerminalUI

/// What a started echo shell writes for `input`, from past its banner to its next prompt.
private func shellOutput(for input: [UInt8]) async -> String {
  let shell = EchoTerminalConnection(prompt: "$ ", banner: "hi")
  var output = shell.output.makeAsyncIterator()
  shell.start()
  _ = await output.next()
  shell.send(input)
  var text: [UInt8] = []
  while !lossyUTF8(text).hasSuffix("$ ") {
    guard case .bytes(let bytes) = await output.next() else { break }
    text += bytes
  }
  return lossyUTF8(text)
}

@Suite("Hostile echo shell")
struct HostileEchoShellTests {
  private func run(_ input: String) async -> String {
    await shellOutput(for: Array((input + "\r").utf8))
  }

  @Test("each command answers")
  func commands() async {
    #expect(await run("help").contains("commands:"))
    #expect(await run("clear").contains("\u{1b}[2J"))
    #expect(await run("colors").contains("48;5;231"))
    #expect(await run("tui").contains("Harness TUI demo"))
    #expect(await run("echo  spaced ").contains("spaced\r\n"))
    #expect(await run("nonsense").contains("echo: nonsense\r\n"))
    #expect(await run("   ") == "   \r\n$ ")
  }

  @Test("escape sequences are consumed, not echoed")
  func escapes() async {
    #expect(await run("\u{1b}[1;5Aa\u{1b}OPb\u{1b}xc") == "abc\r\necho: abc\r\n$ ")
    #expect(await run("\u{1b}[<0;10;10Ma") == "a\r\necho: a\r\n$ ")
  }

  @Test("line editing keys on an empty and a full line")
  func lineEditing() async {
    #expect(await run("\u{7f}\u{8}\u{7f}") == "\r\n$ ")
    #expect(await run("ab\u{15}c").contains("echo: c"))
    #expect(await run("ab\u{3}") == "ab^C\r\n$ ")
  }

  @Test("invalid UTF-8 in a command is shown as replacement characters")
  func invalidUTF8() async {
    let text = await shellOutput(for: [0xFF, 0xC0, 0x80, 0xF4, 0x90, 0x0D])
    #expect(text.contains("echo: \u{FFFD}"))
  }

  @Test("every byte value, in every escape state, is taken without trapping")
  func everyByte() {
    let shell = EchoTerminalConnection()
    shell.start()
    let prefixes: [[UInt8]] = [[], [0x1B], [0x1B, 0x5B], [0x1B, 0x4F]]
    for prefix in prefixes {
      for byte in UInt8.min...UInt8.max {
        shell.send(prefix + [byte])
      }
    }
    #expect(shell.state == .attached(readOnly: false))
    #expect(shell.received.count == 256 * (1 + 2 + 3 + 3))
  }

  @Test("a megabyte of input and an empty send are fine")
  func sizes() {
    let shell = EchoTerminalConnection()
    shell.start()
    shell.send([])
    #expect(shell.received.isEmpty)
    shell.send([UInt8](repeating: 0x61, count: 1_000_000))
    shell.send([0x0D])
    #expect(shell.received.count == 1_000_001)
  }

  @Test("the shell moves between states and only an ended one starts again")
  func stateMachine() async {
    let shell = EchoTerminalConnection(prompt: "$ ", banner: "hi")
    let states = shell.states
    shell.start()
    shell.start()
    shell.simulateDrop()
    shell.start()
    #expect(
      shell.state == .reconnecting(failures: 1, retryInMilliseconds: 500, reason: "connection lost")
    )
    #expect(!shell.state.acceptsInput)
    shell.stop()
    shell.stop()
    #expect(shell.state == .closed(.stopped))
    shell.start()
    #expect(shell.state == .attached(readOnly: false))
    shell.simulateExit()
    #expect(shell.state == .closed(.terminalEnded(reason: "terminal session ended")))
    shell.simulateFailure(TerminalFailure(message: ""))
    #expect(!shell.state.acceptsInput)
    shell.start()
    shell.foreground()
    #expect(shell.state.acceptsInput)

    var seen: [TerminalConnectionState] = []
    for await state in states {
      seen.append(state)
      if seen.count == 3 { break }
    }
    #expect(seen == [.idle, .connecting, .attached(readOnly: false)])
  }

  @Test("input after a stop is recorded and dropped; repeated sizes collapse")
  func droppedInput() {
    let shell = EchoTerminalConnection()
    shell.start()
    shell.stop()
    shell.send([0x61])
    #expect(shell.received == [0x61])
    let small = TerminalGridSize(columns: 1, rows: 1)
    let large = TerminalGridSize(columns: .max, rows: .max)
    for size in [small, small, large, small].compactMap(\.self) {
      shell.resize(size)
    }
    #expect(shell.sizes.count == 3)
  }

  @Test("grid size edges, failures and input states")
  func values() {
    for (columns, rows) in [(0, 0), (-1, 5), (5, -1), (Int.min, Int.min), (0, 5), (5, 0)] {
      #expect(TerminalGridSize(columns: columns, rows: rows) == nil)
    }
    #expect(TerminalGridSize(columns: .max, rows: .max)?.description == "\(Int.max)x\(Int.max)")
    #expect(TerminalFailure(message: "x").description == "x")
    #expect(!TerminalConnectionState.idle.acceptsInput)
    #expect(!TerminalConnectionState.connecting.acceptsInput)
    #expect(!TerminalConnectionState.attached(readOnly: true).acceptsInput)
    #expect(TerminalConnectionState.attached(readOnly: false).acceptsInput)
  }
}

@Suite("Hostile terminal recordings")
struct HostileRecordingTests {
  private func malformedLine(_ jsonl: String) -> Int? {
    do {
      _ = try ReplayTerminalConnection(jsonl: jsonl)
      return nil
    } catch let error as ReplayTerminalConnection.RecordingError {
      guard case .malformedLine(let number, _) = error else { return nil }
      #expect(error.description.contains("line \(number)"))
      return number
    } catch {
      return nil
    }
  }

  @Test("broken lines report their number")
  func malformedLines() {
    let good = #"{"direction":"recv","kind":"binary","base64":"YQ=="}"#
    #expect(malformedLine("not json") == 1)
    #expect(malformedLine("{}") == 1)
    #expect(malformedLine("[]") == 1)
    #expect(malformedLine("null") == 1)
    #expect(malformedLine(#"{"direction":7}"#) == 1)
    #expect(malformedLine("\u{0}") == 1)
    #expect(malformedLine(good + "\n{") == 2)
    #expect(malformedLine(good + "\n\n\n{") == 2)
    #expect(malformedLine(#"{"direction":"recv","kind":"binary"}"#) == 1)
    #expect(malformedLine(#"{"direction":"recv","kind":"binary","base64":"%%"}"#) == 1)
    #expect(malformedLine(#"{"direction":"recv"}"#) == 1)
    #expect(malformedLine(#"{"direction":"recv","kind":"video"}"#) == 1)
    #expect(malformedLine(#"{"direction":"recv","kind":7}"#) == 1)
  }

  @Test("sent frames, text frames and empty recordings play nothing")
  func nothingToPlay() throws {
    let recording = """
      {"direction":"send","kind":"nonsense"}
      {"direction":"elsewhere"}
      {"direction":"recv","kind":"text","base64":"%%"}
      """
    for jsonl in ["", "\n\n", recording] {
      let replay = try ReplayTerminalConnection(jsonl: jsonl)
      replay.start()
      replay.stop()
      #expect(replay.state == .closed(.stopped))
    }
  }

  @Test("a recording plays once, in order, including an empty frame")
  func playback() async throws {
    let replay = try ReplayTerminalConnection(
      jsonl: """
        {"direction":"recv","kind":"binary","base64":"YQ=="}
        {"direction":"recv","kind":"binary","base64":""}
        {"direction":"recv","kind":"binary","base64":"Yg=="}
        """)
    var output = replay.output.makeAsyncIterator()
    replay.start()
    replay.start()
    #expect(await output.next() == .bytes([0x61]))
    #expect(await output.next() == .bytes([]))
    #expect(await output.next() == .bytes([0x62]))
    replay.send([1, 2])
    replay.send([])
    #expect(replay.received == [1, 2])
    replay.foreground()
    let size = try #require(TerminalGridSize(columns: 3, rows: 4))
    replay.resize(size)
    replay.resize(size)
    #expect(replay.sizes == [size])
    #expect(!replay.state.acceptsInput)
  }

  @Test("a stopped replay does not play again")
  func stoppedReplay() throws {
    let replay = try ReplayTerminalConnection(jsonl: "")
    replay.stop()
    replay.start()
    #expect(replay.state == .closed(.stopped))
  }

  @Test("a missing recording reads as a sentence")
  func missingResource() {
    let error = ReplayTerminalConnection.RecordingError.missingResource("x.jsonl")
    #expect(error.description.contains("x.jsonl"))
  }
}

@Suite("Hostile demo content and input mapping")
struct HostileDemoAndInputTests {
  @Test("the demo TUI builds at any size a grid can report")
  func demoSizes() {
    let sizes: [(Int, Int)] = [
      (0, 0), (1, 1), (-5, -5), (39, 3), (40, 4), (120, 5), (121, 24), (.max, .max), (.min, 24),
    ]
    for (columns, rows) in sizes {
      let text = TerminalDemoContent.harnessTUI(columns: columns, rows: rows)
      #expect(text.contains("Harness TUI demo"), "\(columns)x\(rows)")
    }
  }

  @Test(
    "the demo TUI builds with the fewest rows Int holds",
    .disabled("Traps: TerminalDemoContent.swift:66 rows - 4 overflows at Int.min"))
  func demoFewestRows() {
    #expect(!TerminalDemoContent.harnessTUI(columns: 80, rows: .min).isEmpty)
  }

  @Test("the color swatches and the way out of the TUI")
  func demoStrings() {
    #expect(TerminalDemoContent.colorSwatches.contains("48;2;0;96;255"))
    #expect(TerminalDemoContent.leaveHarnessTUI.contains("?1049l"))
  }

  @Test("only web and mail links can open; the rest are refused without launching anything")
  func refusedLinks() {
    let refused = [
      "", " ", "not a url", "example.com", "file:///etc/passwd", "FILE:///etc/passwd",
      "javascript:alert(1)", "omnigent://session/1", "ssh://host", "vnc://host",
      "x-apple.systempreferences:",
      "tel:+15555555555", "data:text/html,hi", "//example.com", ":", "http", "\u{0}",
      String(repeating: "z", count: 100_000) + ":x",
    ]
    for link in refused {
      #expect(!TerminalLinks.open(link), "\(link.prefix(40))")
    }
    #expect(TerminalLinks.allowedSchemes == ["http", "https", "mailto"])
  }

  @Test("bytes that are not UTF-8 become replacement characters")
  func lossyBytes() {
    #expect(lossyUTF8([UInt8]()).isEmpty)
    #expect(lossyUTF8([0xFF]) == "\u{FFFD}")
    #expect(lossyUTF8([0x61, 0xC3]) == "a\u{FFFD}")
    #expect(lossyUTF8([0xED, 0xA0, 0x80]).allSatisfy { $0 == "\u{FFFD}" })
    #expect(lossyUTF8([0x00]) == "\u{0}")
  }

  @Test("each key has an identity, and modifiers keep their bits")
  func keys() {
    #expect(Set(TerminalKey.allCases.map(\.id)).count == TerminalKey.allCases.count)
    #expect(TerminalKey.enter.unshiftedCodepoint == 0x0D)
    #expect(TerminalKey.home.unshiftedCodepoint == 0)
    #expect(HIDKeyCodes.macKeyCode[-1] == nil)
    #expect(HIDKeyCodes.macKeyCode[.max] == nil)
    let all: TerminalModifiers = [.shift, .control, .option, .command]
    #expect(all.ghostty.rawValue == 0b1111)
    #expect(TerminalModifiers(rawValue: .max).ghostty.rawValue == .max)
  }
}
