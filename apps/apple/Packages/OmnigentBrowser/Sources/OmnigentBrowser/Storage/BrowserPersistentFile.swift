public import Foundation
internal import os

/// A versioned JSON file, written atomically (a temporary file renamed into place, so a crash
/// never leaves half a file), either at once or debounced.
///
/// The file holds `{"version": N, "value": ...}`. Reading a file whose version is newer than
/// `version` throws `BrowserError.restoreStateUnsupported`; older versions decode with the
/// current type, whose new fields must be optional or defaulted.
public final class BrowserPersistentFile<Value: Codable> {
  /// Where the file lives.
  public let url: URL
  /// The version written, and the newest one read.
  public let version: Int
  /// The most recent failure of a debounced write, also passed to `onError`.
  public private(set) var lastError: BrowserError?
  /// Called when a debounced write fails.
  public var onError: ((BrowserError) -> Void)?

  private let debounce: Duration
  private var pending: Value?
  private var timer: Task<Void, Never>?

  private struct Envelope: Codable {
    let version: Int
    let value: Value
  }

  private struct VersionOnly: Decodable {
    let version: Int
  }

  /// Creates the file handle; nothing is read or written yet.
  public init(url: URL, version: Int, debounce: Duration = .milliseconds(750)) {
    self.url = url
    self.version = version
    self.debounce = debounce
  }

  /// Reads the value, or nil when the file does not exist.
  public func load() throws(BrowserError) -> Value? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw .storageFailed("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
    }
    let decoder = JSONDecoder()
    do {
      let found = try decoder.decode(VersionOnly.self, from: data).version
      guard found <= version else { throw BrowserError.restoreStateUnsupported(version: found) }
      return try decoder.decode(Envelope.self, from: data).value
    } catch let error as BrowserError {
      throw error
    } catch {
      throw .storageFailed("\(url.lastPathComponent) is damaged: \(error.localizedDescription)")
    }
  }

  /// Reads the value; a damaged file is moved aside (`<name>.damaged-<time>`) so a fresh one can
  /// be written, and the error is returned with nil.
  public func loadMovingAsideIfDamaged() -> (value: Value?, error: BrowserError?) {
    do {
      return (try load(), nil)
    } catch {
      let stamp = Int(Date().timeIntervalSince1970)
      let aside = url.deletingLastPathComponent().appending(
        path: "\(url.lastPathComponent).damaged-\(stamp)")
      do {
        try FileManager.default.moveItem(at: url, to: aside)
      } catch let moveError {
        Logger.storage.error(
          "Could not move \(self.url.path, privacy: .public) aside: \(moveError.localizedDescription, privacy: .public)"
        )
      }
      Logger.storage.error(
        "\(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
      return (nil, error)
    }
  }

  /// Writes `value` now, cancelling any pending debounced write.
  public func write(_ value: Value) throws(BrowserError) {
    timer?.cancel()
    timer = nil
    pending = nil
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try encoder.encode(Envelope(version: version, value: value))
      try data.write(to: url, options: .atomic)
    } catch {
      throw .storageFailed(
        "Could not write \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  /// Writes `value` after the debounce interval; later calls replace it.
  public func schedule(_ value: Value) {
    pending = value
    guard timer == nil else { return }
    timer = Task { [weak self, debounce] in
      do {
        try await Task.sleep(for: debounce)
      } catch {
        return  // Cancelled: a direct write superseded it.
      }
      self?.timer = nil
      self?.flushReportingErrors()
    }
  }

  /// Writes a pending value now.
  public func flush() throws(BrowserError) {
    guard let pending else { return }
    try write(pending)
  }

  /// Whether a debounced write is waiting.
  public var hasPendingWrite: Bool { pending != nil }

  private func flushReportingErrors() {
    do {
      try flush()
      lastError = nil
    } catch {
      lastError = error
      Logger.storage.error(
        "Saving \(self.url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
      )
      onError?(error)
    }
  }
}

extension Logger {
  static let storage = Logger(subsystem: "ai.omnigent.browser", category: "storage")
}
