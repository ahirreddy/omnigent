public import Foundation
public import Observation

/// Where a log line came from.
nonisolated public enum LocalLogSource: Equatable, Sendable {
  /// The process's standard output.
  case standardOutput
  /// The process's standard error.
  case standardError
  /// The app: start, stop, exit and restart events.
  case app
}

/// The most recent output lines of one process, for Show Server Logs.
///
/// Output arrives as raw chunks; this splits them into lines across chunk boundaries, strips
/// ANSI escapes, caps very long lines, and keeps at most `capacity` lines.
@Observable
public final class LocalProcessLog {
  /// One line.
  public struct Line: Identifiable, Equatable, Sendable {
    /// Increasing across the log's lifetime, so views keep identity across trimming.
    public let id: Int
    /// When it was received.
    public let date: Date
    /// Where it came from.
    public let source: LocalLogSource
    /// The text without its newline.
    public let text: String
  }

  /// Lines longer than this are cut, with a marker.
  public static let maximumLineLength = 8_192

  /// How many lines are kept.
  public let capacity: Int
  /// The kept lines, oldest first.
  public private(set) var lines: [Line] = []
  /// Lines dropped to stay within `capacity`.
  public private(set) var droppedLineCount = 0
  @ObservationIgnored private var nextID = 0
  @ObservationIgnored private var partial: [LocalProcessOutput.Stream: Data] = [:]

  /// Creates a log.
  /// - Parameter capacity: Lines to keep.
  public init(capacity: Int = 5_000) {
    self.capacity = max(1, capacity)
  }

  /// Adds a chunk and returns the complete lines it finished.
  /// - Parameter output: The chunk.
  /// - Returns: The new lines' text.
  @discardableResult
  public func append(_ output: LocalProcessOutput) -> [String] {
    var buffer = partial[output.stream, default: Data()]
    buffer.append(output.data)
    var finished: [String] = []
    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
      finished.append(Self.clean(buffer[buffer.startIndex..<newline]))
      buffer = Data(buffer[buffer.index(after: newline)...])
    }
    if buffer.count > Self.maximumLineLength {
      finished.append(Self.clean(buffer))
      buffer = Data()
    }
    partial[output.stream] = buffer
    let source: LocalLogSource =
      output.stream == .standardOutput ? .standardOutput : .standardError
    for text in finished { add(text, source: source) }
    return finished
  }

  /// Emits any unterminated text, for when the process exits.
  public func flush() {
    for (stream, data) in partial where !data.isEmpty {
      add(Self.clean(data), source: stream == .standardOutput ? .standardOutput : .standardError)
    }
    partial = [:]
  }

  /// Adds an app event, such as "Started" or "Exited with status 1".
  /// - Parameter text: The event.
  public func appendEvent(_ text: String) {
    add(text, source: .app)
  }

  /// Removes every line.
  public func clear() {
    lines = []
    droppedLineCount = 0
    partial = [:]
  }

  /// The last `count` process lines, for error messages.
  /// - Parameter count: How many.
  /// - Returns: Their text.
  public func lastProcessLines(_ count: Int) -> [String] {
    lines.lazy.filter { $0.source != .app }.suffix(count).map(\.text)
  }

  /// Every kept line as plain text, for copying.
  public var text: String {
    lines.map { $0.source == .app ? "[Omnigent] \($0.text)" : $0.text }.joined(separator: "\n")
  }

  private func add(_ text: String, source: LocalLogSource) {
    lines.append(Line(id: nextID, date: Date(), source: source, text: text))
    nextID += 1
    // Trim in batches so a busy log does not shift the array on every line.
    if lines.count > capacity + capacity / 10 {
      let excess = lines.count - capacity
      lines.removeFirst(excess)
      droppedLineCount += excess
    }
  }

  /// Decodes UTF-8 (replacing invalid bytes), drops a trailing CR, strips ANSI escapes and caps
  /// the length.
  static func clean(_ bytes: Data) -> String {
    var text = bytes.lossyUTF8
    if text.hasSuffix("\r") { text.removeLast() }
    text = stripANSI(text)
    if text.count > maximumLineLength {
      text = String(text.prefix(maximumLineLength)) + " [line cut]"
    }
    return text
  }

  /// Removes CSI sequences (`ESC [ ... final`) and other two-character escapes.
  static func stripANSI(_ text: String) -> String {
    guard text.contains("\u{1B}") else { return text }
    var result = ""
    var iterator = text.unicodeScalars.makeIterator()
    while let scalar = iterator.next() {
      guard scalar == "\u{1B}" else {
        result.unicodeScalars.append(scalar)
        continue
      }
      guard let next = iterator.next() else { break }
      if next == "[" {
        // Parameters and intermediates run until a final byte in 0x40...0x7E.
        while let byte = iterator.next(), !(0x40...0x7E).contains(byte.value) {}
      }
    }
    return result
  }
}

nonisolated extension Data {
  /// UTF-8 text with invalid bytes replaced by U+FFFD. Process output is not guaranteed to be
  /// UTF-8, and a log line with one bad byte must still be shown rather than dropped, so this is
  /// deliberately the lossy conversion.
  var lossyUTF8: String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: self, as: UTF8.self)
  }
}
