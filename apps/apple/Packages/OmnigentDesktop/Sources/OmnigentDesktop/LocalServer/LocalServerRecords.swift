public import Foundation

/// What the app writes about a process it spawned, so a later launch can find it after a crash.
nonisolated public struct LocalServerRecord: Codable, Equatable, Sendable {
  /// Which process.
  public enum Kind: String, Codable, Sendable, CaseIterable {
    /// `omnigent server`.
    case server
    /// `omnigent host`.
    case host
  }

  /// Which process.
  public var kind: Kind
  /// Its PID and start time. The start time guards against a reused PID.
  public var process: LocalProcessIdentity
  /// The server's port once known; `nil` for hosts and servers still starting.
  public var port: Int?
  /// The server a host connects to.
  public var serverURL: URL?
  /// The command line, for diagnostics.
  public var commandLine: String
  /// When the record was written.
  public var recordedAt: Date

  /// Creates a record.
  /// - Parameters:
  ///   - kind: Which process.
  ///   - process: Its identity.
  ///   - port: The server port.
  ///   - serverURL: The host's server.
  ///   - commandLine: The command line.
  ///   - recordedAt: When.
  public init(
    kind: Kind, process: LocalProcessIdentity, port: Int? = nil, serverURL: URL? = nil,
    commandLine: String, recordedAt: Date = Date()
  ) {
    self.kind = kind
    self.process = process
    self.port = port
    self.serverURL = serverURL
    self.commandLine = commandLine
    self.recordedAt = recordedAt
  }
}

/// Reads and writes `LocalServerRecord`s as JSON files in one directory.
nonisolated public struct LocalServerRecordStore: Sendable {
  /// The directory holding `server.json` and `host.json`.
  public let directory: URL

  /// Creates a store.
  /// - Parameter directory: The directory; created on first write.
  public init(directory: URL) {
    self.directory = directory
  }

  /// `~/Library/Application Support/<bundle identifier>/LocalServer`.
  /// - Parameter bundleIdentifier: Normally `Bundle.main.bundleIdentifier`.
  /// - Returns: The store.
  public static func applicationSupport(bundleIdentifier: String?) -> Self {
    let base = URL.applicationSupportDirectory
      .appending(path: bundleIdentifier ?? "ai.omnigent.desktop", directoryHint: .isDirectory)
    return Self(directory: base.appending(path: "LocalServer", directoryHint: .isDirectory))
  }

  /// The file for a kind.
  /// - Parameter kind: The kind.
  /// - Returns: Its URL.
  public func fileURL(_ kind: LocalServerRecord.Kind) -> URL {
    directory.appending(path: "\(kind.rawValue).json")
  }

  /// Reads a record.
  /// - Parameter kind: Which.
  /// - Returns: The record, or `nil` when none is stored.
  /// - Throws: `LocalServerError.recordFailed` when the file exists but cannot be read.
  public func read(_ kind: LocalServerRecord.Kind) throws(LocalServerError) -> LocalServerRecord? {
    let url = fileURL(kind)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .recordFailed("reading \(url.path): \(error.localizedDescription)")
    }
    do {
      return try JSONDecoder().decode(LocalServerRecord.self, from: data)
    } catch {
      throw .recordFailed("\(url.path) is not a valid record: \(error)")
    }
  }

  /// Writes a record atomically, readable only by the user.
  /// - Parameter record: The record.
  /// - Throws: `LocalServerError.recordFailed`.
  public func write(_ record: LocalServerRecord) throws(LocalServerError) {
    let url = fileURL(record.kind)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(record).write(to: url, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      throw .recordFailed("writing \(url.path): \(error.localizedDescription)")
    }
  }

  /// Deletes a record; a missing one is not an error.
  /// - Parameter kind: Which.
  /// - Throws: `LocalServerError.recordFailed`.
  public func remove(_ kind: LocalServerRecord.Kind) throws(LocalServerError) {
    let url = fileURL(kind)
    do {
      try FileManager.default.removeItem(at: url)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      throw .recordFailed("removing \(url.path): \(error.localizedDescription)")
    }
  }
}

/// The CLI's own record of the machine's canonical local server: `<data dir>/local_server.pid`,
/// two lines (PID, then port), written by `omnigent server` and `omnigent server --background`.
/// Mirrors `_read_local_server_pid_file()` in `omnigent/host/local_server.py`.
nonisolated public struct CanonicalServerRecord: Equatable, Sendable {
  /// The recorded PID.
  public var pid: Int32
  /// The recorded port.
  public var port: Int
  /// When the file was last written.
  public var modified: Date

  /// The pidfile path.
  /// - Parameter dataDirectory: The CLI data directory, normally `~/.omnigent`.
  /// - Returns: The path.
  public static func fileURL(dataDirectory: URL) -> URL {
    dataDirectory.appending(path: "local_server.pid")
  }

  /// Parses the two-line format. Like the CLI, a malformed file counts as no record.
  /// - Parameter text: The file contents.
  /// - Returns: `(pid, port)`, or `nil` when malformed.
  public static func parse(_ text: String) -> (pid: Int32, port: Int)? {
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard lines.count >= 2, let pid = Int32(lines[0]), let port = Int(lines[1]), pid > 0,
      (1...65_535).contains(port)
    else { return nil }
    return (pid, port)
  }

  /// Reads the pidfile.
  /// - Parameter dataDirectory: The CLI data directory.
  /// - Returns: The record, or `nil` when missing or malformed.
  /// - Throws: `LocalServerError.recordFailed` when it exists but cannot be read.
  public static func read(dataDirectory: URL) throws(LocalServerError) -> Self? {
    let url = fileURL(dataDirectory: dataDirectory)
    let text: String
    let modified: Date
    do {
      text = try String(contentsOf: url, encoding: .utf8)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      modified = attributes[.modificationDate] as? Date ?? .distantPast
    } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
      return nil
    } catch {
      throw .recordFailed("reading \(url.path): \(error.localizedDescription)")
    }
    guard let parsed = parse(text) else { return nil }
    return Self(pid: parsed.pid, port: parsed.port, modified: modified)
  }
}
