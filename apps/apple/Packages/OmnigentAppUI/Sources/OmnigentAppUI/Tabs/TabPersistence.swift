import CryptoKit
public import Foundation
public import Observation

/// Saves every window's tabs, one JSON file per server under Application Support, so a
/// relaunch restores them.
///
/// Writes are atomic and debounced. A window registers a snapshot provider, which is read when
/// the write happens (so browser pages save their latest state), and claims a saved window when
/// it opens: its own record when SwiftUI restored the window, else the most recent record from a
/// previous launch that no open window has claimed. Closing a window drops its record; quitting
/// keeps every record.
@Observable
public final class TabPersistence {
  /// A save or restore failure, shown in the tab strip.
  public struct Issue: Error, Hashable, Sendable, CustomStringConvertible {
    /// What failed, for the user.
    public let description: String
  }

  /// Reads a window's tabs at write time; a throw keeps the window's previous record.
  public typealias Provider = @MainActor () throws -> TabWindowSnapshot

  /// The file's format version; newer files are not read (and not overwritten).
  public static let version = 1

  /// The last failure. A save failure clears with the next complete write; a restore failure
  /// stays for the launch.
  public private(set) var issue: Issue?
  @ObservationIgnored private var issueIsFromSaving = false

  @ObservationIgnored private let directory: URL
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private let launch = UUID()
  @ObservationIgnored private var files: [String: TabFile] = [:]
  @ObservationIgnored private var unreadable: Set<String> = []
  @ObservationIgnored private var providers: [String: [UUID: Provider]] = [:]
  @ObservationIgnored private var pending: [String: (server: String, task: Task<Void, Never>)] =
    [:]
  @ObservationIgnored private var claimed: Set<UUID> = []
  @ObservationIgnored private var servers: [String: String] = [:]

  /// Creates the store.
  /// - Parameters:
  ///   - directory: Where the per-server files go.
  ///   - debounce: How long changes collect before a write.
  public init(directory: URL, debounce: Duration = .milliseconds(400)) {
    self.directory = directory
    self.debounce = debounce
  }

  /// The store under `Application Support/<bundle id>/Tabs`.
  /// - Parameter bundleID: The app's bundle id.
  /// - Returns: The store.
  /// - Throws: When Application Support cannot be located.
  public static func applicationSupport(bundleID: String) throws -> TabPersistence {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return TabPersistence(
      directory: base.appending(path: bundleID, directoryHint: .isDirectory)
        .appending(path: "Tabs", directoryHint: .isDirectory))
  }

  /// Claims a saved window for `window` on `server`: its own record if there is one, otherwise
  /// the newest unclaimed record from an earlier launch.
  /// - Parameters:
  ///   - window: The window's stable id.
  ///   - server: The server's URL.
  /// - Returns: The saved tabs, or `nil` for a fresh window.
  public func claim(window: UUID, server: String) -> TabWindowSnapshot? {
    let key = Self.key(server)
    guard var file = load(key, server: server) else { return nil }
    claimed.insert(window)
    if let own = file.windows.first(where: { $0.window == window }) { return own.snapshot }
    let candidates = file.windows.filter { $0.launch != launch && !claimed.contains($0.window) }
    guard let adopted = candidates.max(by: { $0.savedAt < $1.savedAt }) else { return nil }
    // The record moves to this window's id.
    file.windows.removeAll { $0.window == adopted.window }
    file.windows.append(
      TabWindowRecord(
        window: window, launch: launch, savedAt: adopted.savedAt, snapshot: adopted.snapshot))
    files[key] = file
    if !adopted.skipped.isEmpty {
      report("Some saved tabs could not be restored: \(adopted.skipped.joined(separator: "; ")).")
    }
    return adopted.snapshot
  }

  /// Registers a window's tabs for saving and saves them.
  /// - Parameters:
  ///   - window: The window's id.
  ///   - server: The server's URL.
  ///   - snapshot: Reads the window's tabs at write time.
  public func register(window: UUID, server: String, snapshot: @escaping Provider) {
    let key = Self.key(server)
    claimed.insert(window)
    servers[key] = server
    providers[key, default: [:]][window] = snapshot
    scheduleSave(server: server)
  }

  /// Stops saving a window. Closing the window (`keepRecord` false) also drops its saved tabs;
  /// quitting or switching servers keeps them.
  /// - Parameters:
  ///   - window: The window's id.
  ///   - server: The server's URL.
  ///   - keepRecord: Keep the saved tabs for the next launch.
  public func unregister(window: UUID, server: String, keepRecord: Bool) {
    let key = Self.key(server)
    if keepRecord {
      write(key, server: server)
    }
    providers[key]?[window] = nil
    claimed.remove(window)
    if !keepRecord, var file = load(key, server: server) {
      file.windows.removeAll { $0.window == window }
      files[key] = file
      write(key, server: server)
    }
  }

  /// Saves `server`'s windows after the debounce interval.
  /// - Parameter server: The server's URL.
  public func scheduleSave(server: String) {
    let key = Self.key(server)
    pending[key]?.task.cancel()
    let debounce = debounce
    let task = Task { [weak self] in
      do {
        try await Task.sleep(for: debounce)
      } catch {
        // Cancelled by a newer change, which schedules its own write.
        return
      }
      self?.write(key, server: server)
    }
    pending[key] = (server, task)
  }

  /// A window closed for good: stops saving it and drops its saved tabs on every server.
  /// - Parameter window: The window's id.
  public func windowClosed(_ window: UUID) {
    for (key, windows) in providers where windows[window] != nil {
      if let server = servers[key] { unregister(window: window, server: server, keepRecord: false) }
    }
  }

  /// Writes every pending change now, for example when the app quits or moves to the background.
  public func flush() {
    for (key, entry) in pending {
      entry.task.cancel()
      write(key, server: entry.server)
    }
    pending = [:]
  }

  // MARK: Files

  private func load(_ key: String, server: String) -> TabFile? {
    if let file = files[key] { return file }
    if unreadable.contains(key) { return nil }
    let url = fileURL(key)
    guard FileManager.default.fileExists(atPath: url.path) else {
      let file = TabFile(version: Self.version, server: server, windows: [])
      files[key] = file
      return file
    }
    do {
      let file = try JSONDecoder.tabs.decode(TabFile.self, from: Data(contentsOf: url))
      guard file.version <= Self.version else {
        unreadable.insert(key)
        report("Saved tabs are from a newer version of the app and were not restored.")
        return nil
      }
      files[key] = file
      return file
    } catch {
      // Leave the file alone so a fix can still read it; this launch starts without tabs.
      unreadable.insert(key)
      report("Saved tabs could not be read: \(error.localizedDescription)")
      return nil
    }
  }

  private func write(_ key: String, server: String) {
    pending[key] = nil
    guard !unreadable.contains(key), var file = load(key, server: server) else { return }
    let now = Date()
    var complete = true
    for (window, provider) in providers[key] ?? [:] {
      let snapshot: TabWindowSnapshot
      do {
        snapshot = try provider()
      } catch {
        report("Some tabs could not be saved: \(error.localizedDescription)", saving: true)
        complete = false
        continue
      }
      file.windows.removeAll { $0.window == window }
      file.windows.append(
        TabWindowRecord(window: window, launch: launch, savedAt: now, snapshot: snapshot))
    }
    files[key] = file
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder.tabs.encode(file)
      try data.write(to: fileURL(key), options: .atomic)
      if complete, issueIsFromSaving { issue = nil }
    } catch {
      report("Tabs could not be saved: \(error.localizedDescription)", saving: true)
    }
  }

  /// Shows a tab problem found outside the store, for example a page that did not close cleanly.
  /// - Parameter message: What went wrong.
  func reportIssue(_ message: String) {
    report(message)
  }

  private func report(_ message: String, saving: Bool = false) {
    issue = Issue(description: message)
    issueIsFromSaving = saving
  }

  private func fileURL(_ key: String) -> URL {
    directory.appending(path: "\(key).json", directoryHint: .notDirectory)
  }

  /// A file name for a server: a digest of its normalized URL.
  static func key(_ server: String) -> String {
    var text = server.lowercased()
    while text.hasSuffix("/") { text.removeLast() }
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.prefix(12).map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0\(hex)" : hex
    }.joined()
  }
}

/// One server's saved windows.
nonisolated struct TabFile: Codable, Sendable {
  var version: Int
  /// The server, for people reading the file.
  var server: String
  var windows: [TabWindowRecord]
}

/// One window's saved tabs.
nonisolated struct TabWindowRecord: Codable, Sendable {
  var window: UUID
  /// The launch that wrote it; records from this launch are never adopted by another window.
  var launch: UUID
  var savedAt: Date
  var snapshot: TabWindowSnapshot
  /// Tabs that could not be decoded (a kind from a newer app), reported once on restore.
  var skipped: [String] = []

  init(window: UUID, launch: UUID, savedAt: Date, snapshot: TabWindowSnapshot) {
    self.window = window
    self.launch = launch
    self.savedAt = savedAt
    self.snapshot = snapshot
  }

  private enum CodingKeys: String, CodingKey {
    case window, launch, savedAt, selectedID, tabs, closed
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    window = try container.decode(UUID.self, forKey: .window)
    launch = try container.decode(UUID.self, forKey: .launch)
    savedAt = try container.decode(Date.self, forKey: .savedAt)
    let tabs = try container.decode([LenientTab].self, forKey: .tabs)
    let closed = try container.decodeIfPresent([LenientTab].self, forKey: .closed) ?? []
    snapshot = TabWindowSnapshot(
      tabs: tabs.compactMap(\.tab),
      selectedID: try container.decodeIfPresent(String.self, forKey: .selectedID),
      closed: closed.compactMap(\.tab))
    skipped = (tabs + closed).compactMap(\.problem)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(window, forKey: .window)
    try container.encode(launch, forKey: .launch)
    try container.encode(savedAt, forKey: .savedAt)
    try container.encode(snapshot.tabs, forKey: .tabs)
    try container.encodeIfPresent(snapshot.selectedID, forKey: .selectedID)
    try container.encode(snapshot.closed, forKey: .closed)
  }
}

/// A tab that decodes to `nil` with the reason when its kind is unknown, so one bad tab does
/// not lose the window.
nonisolated private struct LenientTab: Decodable {
  let tab: AppTab?
  let problem: String?

  init(from decoder: any Decoder) throws {
    do {
      tab = try AppTab(from: decoder)
      problem = nil
    } catch {
      tab = nil
      problem = String(describing: error)
    }
  }
}

extension JSONEncoder {
  fileprivate static var tabs: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var tabs: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
