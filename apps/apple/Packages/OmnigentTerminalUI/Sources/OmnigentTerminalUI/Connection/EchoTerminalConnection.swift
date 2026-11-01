import Foundation

/// A fake remote shell for previews, the gallery and tests.
///
/// It behaves like a tiny line-editing shell on the far side of a socket: it echoes printable
/// input, handles backspace, Ctrl-C and Enter, and answers a few commands (`echo`, `clear`,
/// `colors`, `tui`, `help`). Escape sequences (arrows, function keys, mouse reports) are recorded
/// but not echoed, as a real shell's line editor would consume them.
public final class EchoTerminalConnection: TerminalConnection {
  /// Renderer input, in order.
  public let output: AsyncStream<TerminalOutput>
  /// State changes, starting with the current state.
  public let states: AsyncStream<TerminalConnectionState>
  /// The current state.
  public private(set) var state: TerminalConnectionState = .idle

  /// Every byte sent by the renderer, in order.
  public private(set) var received: [UInt8] = []
  /// Every grid size reported by the renderer, in order.
  public private(set) var sizes: [TerminalGridSize] = []
  /// The prompt printed after each command.
  public let prompt: String

  private let outputContinuation: AsyncStream<TerminalOutput>.Continuation
  private let stateContinuation: AsyncStream<TerminalConnectionState>.Continuation
  private let readOnly: Bool
  private let banner: String
  private var line: [UInt8] = []
  private var escape: EscapeState = .none

  private enum EscapeState {
    case none
    case escape
    case csi
    case ss3
  }

  /// An echo shell. `readOnly` makes it behave like a viewer attach: input is dropped.
  public init(
    prompt: String = "omnigent:~$ ",
    banner: String = "Omnigent echo shell. Type help for commands.",
    readOnly: Bool = false
  ) {
    self.prompt = prompt
    self.banner = banner
    self.readOnly = readOnly
    (output, outputContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    stateContinuation.yield(.idle)
  }

  /// Attaches.
  public func start() {
    switch state {
    case .connecting, .attached, .reconnecting: return
    case .idle, .closed, .failed: break
    }
    set(.connecting)
    set(.attached(readOnly: readOnly))
    write("\u{1b}[1;36m\(banner)\u{1b}[0m\r\n\(prompt)")
  }

  /// Detaches.
  public func stop() {
    set(.closed(.stopped))
  }

  /// The app or window became visible.
  public func foreground() {}

  /// Records the renderer's grid size.
  public func resize(_ size: TerminalGridSize) {
    if sizes.last != size { sizes.append(size) }
  }

  /// Receives encoded input bytes.
  public func send(_ bytes: [UInt8]) {
    received += bytes
    guard state.acceptsInput else { return }
    for byte in bytes { feed(byte) }
  }

  /// Ends the fake session as if the remote program exited.
  public func simulateExit() {
    write("\r\n\u{1b}[2m[process exited]\u{1b}[0m\r\n")
    set(.closed(.terminalEnded(reason: "terminal session ended")))
  }

  /// Simulates a dropped connection that is being retried.
  public func simulateDrop() {
    set(.reconnecting(failures: 1, retryInMilliseconds: 500, reason: "connection lost"))
  }

  /// Simulates a failed attach.
  public func simulateFailure(_ failure: TerminalFailure) {
    set(.failed(failure))
  }

  /// Writes raw bytes to the renderer, as remote output.
  public func emit(_ bytes: [UInt8]) {
    outputContinuation.yield(.bytes(bytes))
  }

  private func set(_ newState: TerminalConnectionState) {
    guard state != newState else { return }
    state = newState
    stateContinuation.yield(newState)
  }

  private func write(_ text: String) {
    emit(Array(text.utf8))
  }

  private func feed(_ byte: UInt8) {
    if consumeEscape(byte) { return }
    switch byte {
    case 0x1B:
      escape = .escape
    case 0x0D:
      let command = lossyUTF8(line)
      line.removeAll()
      write("\r\n")
      run(command)
      write(prompt)
    case 0x7F, 0x08:
      guard !line.isEmpty else { return }
      line.removeLast()
      write("\u{8} \u{8}")
    case 0x03:
      line.removeAll()
      write("^C\r\n\(prompt)")
    case 0x15:
      write(String(repeating: "\u{8} \u{8}", count: line.count))
      line.removeAll()
    case 0x20...0x7E, 0x80...0xFF:
      line.append(byte)
      emit([byte])
    default:
      break
    }
  }

  /// Swallows the rest of an escape sequence, as a line editor consumes arrows and mouse
  /// reports. Returns whether `byte` belonged to one.
  private func consumeEscape(_ byte: UInt8) -> Bool {
    switch escape {
    case .none:
      return false
    case .escape:
      escape = byte == UInt8(ascii: "[") ? .csi : (byte == UInt8(ascii: "O") ? .ss3 : .none)
    case .csi:
      // A CSI sequence ends with a final byte in 0x40...0x7E.
      if (0x40...0x7E).contains(byte) { escape = .none }
    case .ss3:
      escape = .none
    }
    return true
  }

  private func run(_ command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "":
      return
    case "help":
      write("commands: echo <text>, clear, colors, tui, help\r\n")
    case "clear":
      write("\u{1b}[H\u{1b}[2J")
    case "colors":
      write(TerminalDemoContent.colorSwatches)
    case "tui":
      write(TerminalDemoContent.harnessTUI(columns: sizes.last?.columns ?? 80))
    default:
      if trimmed.hasPrefix("echo ") {
        write(String(trimmed.dropFirst(5)) + "\r\n")
      } else {
        write("echo: \(trimmed)\r\n")
      }
    }
  }
}
