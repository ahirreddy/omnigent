import Foundation
import Testing

@testable import OmnigentTerminalUI

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}

@Suite("Ghostty surface over a remote connection", .serialized)
struct SurfaceRoundTripTests {
  @Test("remote output renders and typed input round-trips through the connection")
  func echoRoundTrip() async throws {
    let connection = EchoTerminalConnection()
    let controller = try TerminalSurfaceController(connection: connection)
    let host = try SurfaceHost(controller: controller, width: 640, height: 360)
    #expect(await eventually { controller.visibleText().contains("Omnigent echo shell") })
    #expect(await eventually { controller.state == .attached(readOnly: false) })
    #expect(controller.gridSize != nil, "the view reported a grid")
    #expect(connection.sizes.last == controller.gridSize)

    controller.type("echo round-trip")
    controller.press(.enter)
    #expect(await eventually { controller.visibleText().contains("round-trip\n") })
    let sent = lossyUTF8(connection.received)
    #expect(sent == "echo round-trip\r")
    try host.snapshot(named: "echo-roundtrip")
  }

  @Test("arrow keys follow the program's cursor-key mode")
  func cursorKeyModes() async throws {
    let connection = EchoTerminalConnection()
    let controller = try TerminalSurfaceController(connection: connection)
    _ = try SurfaceHost(controller: controller, width: 480, height: 240)
    #expect(await eventually { controller.visibleText().contains("echo shell") })
    controller.press(.arrowUp)
    #expect(await eventually { connection.received == Array("\u{1b}[A".utf8) })
    // DECCKM: the program asks for application cursor keys.
    connection.emit(Array("\u{1b}[?1h".utf8))
    try await Task.sleep(for: .milliseconds(100))
    controller.press(.arrowUp)
    #expect(await eventually { connection.received.suffix(3) == Array("\u{1b}OA".utf8) })
  }

  @Test("kitty keyboard and bracketed paste modes set by the program shape the encoded bytes")
  func harnessModes() async throws {
    let connection = EchoTerminalConnection()
    let controller = try TerminalSurfaceController(connection: connection)
    _ = try SurfaceHost(controller: controller, width: 480, height: 240)
    #expect(await eventually { controller.visibleText().contains("echo shell") })
    // Kitty keyboard flag 1 (disambiguate): Escape becomes CSI 27 u.
    connection.emit(Array("\u{1b}[>1u".utf8))
    try await Task.sleep(for: .milliseconds(100))
    controller.press(.escape)
    #expect(await eventually { connection.received.suffix(5) == Array("\u{1b}[27u".utf8) })
    connection.emit(Array("\u{1b}[<u\u{1b}[?2004h".utf8))
    try await Task.sleep(for: .milliseconds(100))
    controller.paste("pasted text")
    let expected = Array("\u{1b}[200~pasted text\u{1b}[201~".utf8)
    #expect(await eventually { connection.received.suffix(expected.count) == expected })
  }

  @Test("a reattach resets the screen before the new seed")
  func resetScreen() async throws {
    let connection = EchoTerminalConnection()
    let controller = try TerminalSurfaceController(connection: connection)
    _ = try SurfaceHost(controller: controller, width: 480, height: 240)
    #expect(await eventually { controller.visibleText().contains("echo shell") })
    controller.render(.resetScreen)
    connection.emit(Array("seed after reconnect".utf8))
    #expect(await eventually { controller.visibleText().contains("seed after reconnect") })
    #expect(!controller.visibleText().contains("echo shell"))
  }

  @Test("the recorded REPL TUI renders")
  func recordedTUI() async throws {
    let connection = try ReplayTerminalConnection.recordedReplTUI()
    let controller = try TerminalSurfaceController(connection: connection)
    let host = try SurfaceHost(controller: controller, width: 900, height: 560)
    #expect(await eventually { controller.visibleText().contains("Choose your theme") })
    try await Task.sleep(for: .milliseconds(300))
    try host.snapshot(named: "repl-tui-recorded")
  }

  @Test("the synthesized harness TUI renders with alternate screen and truecolor")
  func synthesizedTUI() async throws {
    let connection = EchoTerminalConnection()
    let controller = try TerminalSurfaceController(connection: connection)
    let host = try SurfaceHost(controller: controller, width: 900, height: 560)
    #expect(await eventually { controller.visibleText().contains("echo shell") })
    let columns = controller.gridSize?.columns ?? 80
    let rows = controller.gridSize?.rows ?? 24
    connection.emit(Array(TerminalDemoContent.harnessTUI(columns: columns, rows: rows).utf8))
    #expect(await eventually { controller.visibleText().contains("Harness TUI demo") })
    try await Task.sleep(for: .milliseconds(300))
    try host.snapshot(named: "harness-tui")
    connection.emit(Array(TerminalDemoContent.leaveHarnessTUI.utf8))
    #expect(await eventually { controller.visibleText().contains("echo shell") })
  }
}
