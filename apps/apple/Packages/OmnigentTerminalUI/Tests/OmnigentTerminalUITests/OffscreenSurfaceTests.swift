import AppKit
import Foundation
import Testing

@testable import OmnigentTerminalUI

@Suite("Surface in a never-shown window", .serialized)
struct OffscreenSurfaceTests {
  @Test("output renders, typed input round-trips and the grid reaches the connection")
  func roundTrip() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    #expect(surface.controller.state == .attached(readOnly: false))
    #expect(surface.controller.gridSize != nil)
    #expect(surface.connection.sizes.last == surface.controller.gridSize)
    surface.controller.type("echo round-trip")
    surface.controller.press(.enter)
    #expect(await eventually { surface.controller.visibleText().contains("round-trip\n") })
    #expect(lossyUTF8(surface.connection.received) == "echo round-trip\r")
  }

  @Test("connection states reach the controller, and a closed connection still renders")
  func statesFollowTheConnection() async throws {
    let surface = try NeverShownSurface()
    let controller = surface.controller
    surface.connection.simulateDrop()
    #expect(await eventually { !controller.state.acceptsInput })
    surface.connection.simulateFailure(TerminalFailure(message: "nope"))
    #expect(await eventually { controller.state == .failed(TerminalFailure(message: "nope")) })
    surface.connection.simulateExit()
    #expect(await eventually { controller.visibleText().contains("process exited") })
    controller.press(.enter)
    surface.connection.start()
    #expect(await eventually { controller.state == .attached(readOnly: false) })
  }

  @Test("a read-only attach drops what is typed")
  func readOnly() async throws {
    let surface = try NeverShownSurface(
      connection: EchoTerminalConnection(prompt: "$ ", banner: "ready", readOnly: true))
    #expect(await surface.ready())
    surface.controller.type("x")
    #expect(await eventually { surface.connection.received == [0x78] })
    #expect(!surface.controller.visibleText().contains("x\n$"))
  }

  @Test("a recorded TUI replays without a real window on screen")
  func recording() async throws {
    let controller = try TerminalSurfaceController(
      connection: ReplayTerminalConnection.recordedReplTUI())
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 560)
    #expect(await eventually { controller.visibleText().contains("Choose your theme") })
  }

  @Test("sizes with no pixels are ignored and a one-point surface still works")
  func oddSizes() async throws {
    let surface = try NeverShownSurface()
    let controller = surface.controller
    #expect(await surface.ready())
    let before = controller.gridSize
    let ignored: [(CGSize, CGFloat)] = [
      (CGSize.zero, 2), (CGSize(width: -5, height: 10), 2),
      (CGSize(width: 10, height: -5), 2), (CGSize(width: CGFloat.nan, height: 10), 2),
      (CGSize(width: 10, height: CGFloat.infinity), 2), (CGSize(width: 100, height: 100), 0),
      (CGSize(width: 100, height: 100), .nan), (CGSize(width: 0.4, height: 0.4), 1),
      (CGSize(width: 100, height: 100), -1),
      (CGSize(width: CGFloat.leastNonzeroMagnitude, height: 10), 1),
    ]
    for (points, scale) in ignored {
      controller.resize(points: points, scale: scale)
      #expect(controller.gridSize == before)
    }
    controller.resize(points: CGSize(width: 1, height: 1), scale: 1)
    #expect(await surface.survives(Array("wrap this line".utf8), marker: "x"))
    controller.resize(points: CGSize(width: 4_000, height: 3_000), scale: 1)
    #expect(controller.gridSize.map { $0.columns > 100 && $0.rows > 50 } == true)
    #expect(await surface.survives(Array("large".utf8), marker: "large-marker"))
    controller.resize(points: CGSize(width: 480, height: 240), scale: 2)
    #expect(await surface.survives([], marker: "small-marker"))
  }

  @Test("a negative scale with a negative size")
  func negativeScale() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.resize(points: CGSize(width: -480, height: -240), scale: -2)
    #expect(await surface.survives([], marker: "after-negative"))
  }

  @Test("a tiny scale with a huge size")
  func tinyScale() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.resize(points: CGSize(width: 1e6, height: 1e6), scale: 0.0005)
    #expect(await surface.survives([], marker: "m"))
  }

  @Test("a huge scale with a tiny size")
  func hugeScale() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.resize(points: CGSize(width: 0.5, height: 0.5), scale: 2_000)
    #expect(await surface.survives([], marker: "m"))
  }

  @Test("surfaces can be created and dropped repeatedly with output in flight")
  func churn() async throws {
    for round in 0..<12 {
      let surface = try NeverShownSurface()
      surface.connection.emit([UInt8](repeating: 0x61, count: 10_000))
      surface.controller.press(.enter)
      if round.isMultiple(of: 2) { await Task.yield() }
    }
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    #expect(controller.gridSize == nil)
    #expect(!controller.hasSelection)
  }

  @Test("a controller without a window answers commands")
  func noWindow() throws {
    let controller = try TerminalSurfaceController(connection: EchoTerminalConnection())
    controller.setFocused(true)
    controller.setFocused(false)
    controller.focus()
    controller.selectAll()
    controller.type("")
    controller.paste("")
    controller.feed([])
    controller.renderNow()
    #expect(controller.title == nil)
  }

  @Test("the runtime applies appearance changes to live surfaces and rejects nothing it took")
  func runtimeUpdates() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let runtime = surface.controller.runtime
    let original = runtime.appearance
    var edited = original
    for scheme in TerminalColorScheme.allCases {
      edited.colorScheme = scheme
      try runtime.update(appearance: edited)
      try runtime.update(appearance: edited)
    }
    edited.fontSize = 32
    edited.scrollback = .small
    edited.cursorBlink.toggle()
    try runtime.update(appearance: edited)
    #expect(runtime.appearance == edited)
    #expect(await surface.survives([], marker: "after-update"))
    runtime.setFocused(false)
    try runtime.update(appearance: original)
  }

  @Test("the runtime survives odd font sizes on a live surface")
  func runtimeOddFontSizes() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let runtime = surface.controller.runtime
    let original = runtime.appearance
    for size in [0.0, -3, .nan, 0.0001, 100_000] {
      var edited = original
      edited.fontSize = size
      do {
        try runtime.update(appearance: edited)
      } catch {
        #expect(!error.description.isEmpty)
      }
    }
    try runtime.update(appearance: original)
    #expect(await surface.survives([], marker: "after-odd-sizes"))
  }
}

@Suite("Terminal commands on a never-shown surface", .serialized)
struct OffscreenCommandTests {
  @Test("actions Ghostty does not know are refused")
  func unknownActions() throws {
    let controller = try NeverShownSurface().controller
    for action in [
      "", " ", "nonsense", "search", "\u{0}", "::::", String(repeating: "x", count: 100_000),
    ] {
      #expect(!controller.perform(action), "\(action.prefix(20))")
    }
  }

  @Test("find counts matches, moves through them and closes")
  func search() async throws {
    let surface = try NeverShownSurface()
    let controller = surface.controller
    #expect(await surface.ready())
    controller.feed(Array("needle one\r\nneedle two\r\nneedle three\r\n".utf8))
    controller.startSearch()
    #expect(controller.search != nil)
    controller.updateSearch("needle")
    #expect(controller.search?.needle == "needle")
    #expect(await eventually { controller.search?.total == 3 })
    controller.searchNext()
    #expect(await eventually { controller.search?.selected != nil })
    controller.searchNext(backwards: true)
    controller.endSearch()
    #expect(await eventually { controller.search == nil })
  }

  @Test("find takes hostile needles")
  func hostileNeedles() async throws {
    let surface = try NeverShownSurface()
    let controller = surface.controller
    #expect(await surface.ready())
    controller.startSearch()
    let needles = [
      "", "\u{0}", "a\u{0}b", "\n", "👩‍👩‍👧‍👦", "\u{202E}x", "e\u{0301}", ":",
      String(repeating: "W", count: 100_000), "search:nested",
    ]
    for needle in needles {
      controller.updateSearch(needle)
      controller.searchNext()
      controller.searchNext(backwards: true)
      await Task.yield()
    }
    controller.endSearch()
    controller.endSearch()
    controller.searchNext()
    #expect(await surface.survives([], marker: "after-needles"))
  }

  @Test("typed and pasted text with control characters stays intact in bytes")
  func hostileText() async throws {
    let surface = try NeverShownSurface()
    let controller = surface.controller
    #expect(await surface.ready())
    let samples = [
      "👩‍👩‍👧‍👦", "\u{202E}x", "e\u{0301}", "a\u{0}b", "\u{1b}[31m", "line\nline", "\r",
      String(repeating: "W", count: 100_000),
    ]
    for sample in samples {
      controller.type(sample)
      controller.paste(sample)
    }
    #expect(await eventually { !surface.connection.received.isEmpty })
    #expect(await surface.survives([], marker: "after-text"))
  }

  @Test("every key with every modifier encodes without trapping")
  func everyKey() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    for key in TerminalKey.allCases {
      for bits in UInt32(0)..<16 {
        surface.controller.press(key, modifiers: TerminalModifiers(rawValue: bits))
      }
    }
    surface.controller.press(.enter, modifiers: TerminalModifiers(rawValue: .max))
    #expect(await surface.survives([], marker: "after-keys"))
  }

  @Test("an arrow key is encoded for the program")
  func arrowKey() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.press(.arrowUp)
    #expect(await eventually { surface.connection.received == Array("\u{1b}[A".utf8) })
  }

  @Test("the remote clipboard asks or refuses, and the banner state clears")
  func remoteClipboard() throws {
    let controller = try NeverShownSurface().controller
    let defaults = UserDefaults.standard
    try #require(TerminalClipboardPolicy.current(defaults) == .ask)
    controller.render(.clipboardWrite(""))
    #expect(controller.pendingClipboard?.text.isEmpty == true)
    let first = controller.pendingClipboard?.id
    controller.render(.clipboardWrite("\u{0}\n👩‍👩‍👧‍👦"))
    #expect(controller.pendingClipboard?.text == "\u{0}\n👩‍👩‍👧‍👦")
    #expect(controller.pendingClipboard?.id != first)
    controller.declinePendingClipboard()
    controller.declinePendingClipboard()
    #expect(controller.pendingClipboard == nil)
    controller.remoteCopied("x", policy: .block)
    #expect(controller.pendingClipboard == nil)
    #expect(controller.lastError != nil)
    controller.clearError()
    controller.report("")
    #expect(controller.lastError?.isEmpty == true)
    controller.clearError()
    #expect(controller.lastError == nil)
  }

  @Test("select all selects, and an idle surface reports its screen")
  func selection() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    #expect(!surface.controller.hasSelection)
    surface.controller.selectAll()
    #expect(await eventually { surface.controller.hasSelection })
    surface.controller.render(.resetScreen)
    #expect(await eventually { !surface.controller.visibleText().contains("ready") })
  }
}
