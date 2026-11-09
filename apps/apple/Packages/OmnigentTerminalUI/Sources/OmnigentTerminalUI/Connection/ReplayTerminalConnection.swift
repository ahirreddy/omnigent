import Foundation

/// Plays back a recorded attach (the `client-core/fixtures/terminal/*.jsonl` format) as if the
/// server were sending it. Input is recorded and otherwise ignored.
public final class ReplayTerminalConnection: TerminalConnection {
  /// Why a recording could not be read.
  public enum RecordingError: Error, Equatable, CustomStringConvertible {
    /// The bundled recording is missing from the package resources.
    case missingResource(String)
    /// A line is not a recorded frame.
    case malformedLine(number: Int, detail: String)

    /// A readable description.
    public var description: String {
      switch self {
      case .missingResource(let name): "The recording \(name) is missing from the bundle."
      case .malformedLine(let number, let detail): "Recording line \(number): \(detail)"
      }
    }
  }

  /// Renderer input, in order.
  public let output: AsyncStream<TerminalOutput>
  /// State changes, starting with the current state.
  public let states: AsyncStream<TerminalConnectionState>
  /// The current state.
  public private(set) var state: TerminalConnectionState = .idle
  /// Every byte the renderer sent.
  public private(set) var received: [UInt8] = []
  /// Every grid size the renderer reported.
  public private(set) var sizes: [TerminalGridSize] = []

  private let frames: [TerminalOutput]
  private let outputContinuation: AsyncStream<TerminalOutput>.Continuation
  private let stateContinuation: AsyncStream<TerminalConnectionState>.Continuation

  /// A replay of the server → client frames in `jsonl`.
  ///
  /// - Throws: ``RecordingError/malformedLine(number:detail:)``.
  public init(jsonl: String) throws {
    var frames: [TerminalOutput] = []
    for (index, line) in jsonl.split(separator: "\n").enumerated() {
      let data = Data(line.utf8)
      let decoded: Recorded
      do {
        decoded = try JSONDecoder().decode(Recorded.self, from: data)
      } catch {
        throw RecordingError.malformedLine(number: index + 1, detail: "\(error)")
      }
      guard decoded.direction == "recv" else { continue }
      switch decoded.kind {
      case "binary":
        guard let base64 = decoded.base64, let bytes = Data(base64Encoded: base64) else {
          throw RecordingError.malformedLine(number: index + 1, detail: "bad base64 payload")
        }
        frames.append(.bytes(Array(bytes)))
      case "text":
        continue
      default:
        throw RecordingError.malformedLine(
          number: index + 1, detail: "unknown kind \(decoded.kind ?? "nil")")
      }
    }
    self.frames = frames
    (output, outputContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    stateContinuation.yield(.idle)
  }

  /// The recorded embedded Omnigent REPL TUI (`recorded-attach-repl-tui.jsonl`).
  ///
  /// - Throws: ``RecordingError``.
  public static func recordedReplTUI() throws -> ReplayTerminalConnection {
    try recordedReplTUI(resources: .module)
  }

  static func recordedReplTUI(resources: Bundle) throws -> ReplayTerminalConnection {
    guard let url = resources.url(forResource: "repl-tui", withExtension: "jsonl") else {
      throw RecordingError.missingResource("repl-tui.jsonl")
    }
    return try ReplayTerminalConnection(jsonl: try String(contentsOf: url, encoding: .utf8))
  }

  /// Attaches.
  public func start() {
    guard state == .idle else { return }
    state = .attached(readOnly: true)
    stateContinuation.yield(state)
    for frame in frames { outputContinuation.yield(frame) }
  }

  /// Detaches.
  public func stop() {
    state = .closed(.stopped)
    stateContinuation.yield(state)
  }

  /// The app or window became visible.
  public func foreground() {}

  /// Receives encoded input bytes.
  public func send(_ bytes: [UInt8]) {
    received += bytes
  }

  /// Records the renderer's grid size.
  public func resize(_ size: TerminalGridSize) {
    if sizes.last != size { sizes.append(size) }
  }

  private struct Recorded: Decodable {
    let direction: String
    let kind: String?
    let base64: String?
  }
}
