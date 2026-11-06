import CryptoKit
public import Foundation
public import Observation
public import OmnigentUIComponents

/// A window's tabs as they are saved: the page it shows and the session groups that changed.
public struct TabWindowState {
  /// The session or session-less page the window shows.
  public var page: SidebarDestination?
  /// Groups changed since they were made, by session.
  public var groups: [String: TabGroupState]

  /// Creates a state.
  /// - Parameters:
  ///   - page: The page.
  ///   - groups: Changed groups.
  public init(page: SidebarDestination?, groups: [String: TabGroupState] = [:]) {
    self.page = page
    self.groups = groups
  }
}

/// One session's tabs in a window, and when they last changed (`nil`: untouched since made).
public struct TabGroupState {
  /// The tabs.
  public var snapshot: TabWindowSnapshot
  /// When they last changed.
  public var changedAt: Date?

  /// Creates a state.
  /// - Parameters:
  ///   - snapshot: The tabs.
  ///   - changedAt: The last change.
  public init(snapshot: TabWindowSnapshot, changedAt: Date?) {
    self.snapshot = snapshot
    self.changedAt = changedAt
  }
}

/// Saves each session's tabs and each window's page, one JSON file per server under Application
/// Support, so a relaunch restores them. A session's tabs are shared by every window: the window
/// that changed them last writes them, and a window showing the session for the first time gets
/// the newest, from another open window or from the file.
///
/// Writes are atomic and debounced. A window registers a provider, read when the write happens
/// (so browser pages save their latest state), and claims a saved page when it opens: its own
/// record when SwiftUI restored the window, else the most recent record from a previous launch
/// that no open window has claimed. Closing a window drops its page, never sessions' tabs.
@Observable
public final class TabPersistence {
  /// A save or restore failure, shown in the tab strip.
  public struct Issue: Error, Hashable, Sendable, CustomStringConvertible {
    /// What failed, for the user.
    public let description: String
  }

  /// Reads a window's tabs at write time; a throw keeps the window's previous records.
  public typealias Provider = @MainActor () throws -> TabWindowState
  /// Reads one session's tabs in a window, `nil` when the window has none for it.
  public typealias GroupProvider = @MainActor (String) -> TabGroupState?

  /// The file's format version; newer files are not read (and not overwritten).
  public static let version = 2
  /// How many sessions' tabs are kept; the least recently changed go first.
  public static let sessionLimit = 300

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
  @ObservationIgnored private var groupProviders: [String: [UUID: GroupProvider]] = [:]
  @ObservationIgnored private var pending: [String: (server: String, task: Task<Void, Never>)] =
    [:]
  @ObservationIgnored private var claimed: Set<UUID> = []
  @ObservationIgnored private var servers: [String: String] = [:]
  /// Sessions archived or deleted this launch, and when, so a window's older copy is not saved.
  @ObservationIgnored private var removedAt: [String: Date] = [:]
  /// When each session's saved tabs last changed, by file and session, also for those saved as
  /// none (just the chat), so an older copy in another window never wins.
  @ObservationIgnored private var mergedAt: [String: Date] = [:]

  /// Creates the store.
  /// - Parameters:
  ///   - directory: Where the per-server files go.
  ///   - debounce: How long changes collect before a write.
  public init(directory: URL, debounce: Duration = .milliseconds(400)) {
    self.directory = directory
    self.debounce = debounce
  }

  /// The store under `Application Support/<bundle id>`.
  /// - Parameters:
  ///   - bundleID: The app's bundle id.
  ///   - isDemo: The app runs the offline demo server.
  /// - Returns: The store.
  /// - Throws: When Application Support cannot be located.
  public static func applicationSupport(bundleID: String, isDemo: Bool = false) throws
    -> TabPersistence
  {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return TabPersistence(directory: directory(in: base, bundleID: bundleID, isDemo: isDemo))
  }

  /// `<base>/<bundle id>/Tabs`, or `Demo Tabs` for the demo: its server URL is the local
  /// server's, whose saved tabs it must neither restore nor overwrite.
  static func directory(in base: URL, bundleID: String, isDemo: Bool) -> URL {
    base.appending(path: bundleID, directoryHint: .isDirectory)
      .appending(path: isDemo ? "Demo Tabs" : "Tabs", directoryHint: .isDirectory)
  }

  /// Claims a saved window for `window` on `server`: its own record if there is one, otherwise
  /// the newest unclaimed record from an earlier launch.
  /// - Parameters:
  ///   - window: The window's stable id.
  ///   - server: The server's URL.
  /// - Returns: The page the window showed, or `nil` for a fresh window.
  public func claim(window: UUID, server: String) -> SidebarDestination? {
    let key = Self.key(server)
    guard var file = load(key, server: server) else { return nil }
    claimed.insert(window)
    if let own = file.windows.first(where: { $0.window == window }) {
      return own.page?.destination
    }
    let candidates = file.windows.filter { $0.launch != launch && !claimed.contains($0.window) }
    guard let adopted = candidates.max(by: { $0.savedAt < $1.savedAt }) else { return nil }
    // The record moves to this window's id.
    file.windows.removeAll { $0.window == adopted.window }
    file.windows.append(
      TabWindowRecord(
        window: window, launch: launch, savedAt: adopted.savedAt, page: adopted.page))
    files[key] = file
    return adopted.page?.destination
  }

  /// A session's newest saved tabs: another open window's, or the file's.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - server: The server's URL.
  ///   - window: The window asking, whose own tabs are not read.
  /// - Returns: The tabs, or `nil` when the session has none saved.
  public func savedTabs(session sessionID: String, server: String, for window: UUID)
    -> TabWindowSnapshot?
  {
    let key = Self.key(server)
    // A session saved as just its chat, or removed, counts with no tabs.
    let cleared = [mergedAt["\(key)/\(sessionID)"], removedAt[sessionID]].compactMap(\.self).max()
    var newest: (snapshot: TabWindowSnapshot?, date: Date)? = cleared.map { (nil, $0) }
    if var file = load(key, server: server), let record = file.sessions[sessionID],
      record.savedAt >= newest?.date ?? .distantPast
    {
      newest = (record.snapshot, record.savedAt)
      if !record.skipped.isEmpty {
        report("Some saved tabs could not be restored: \(record.skipped.joined(separator: "; ")).")
        file.sessions[sessionID]?.skipped = []
        files[key] = file
      }
    }
    for (other, provider) in groupProviders[key] ?? [:] where other != window {
      guard let live = provider(sessionID) else { continue }
      let date = live.changedAt ?? .distantPast
      if newest.map({ date > $0.date }) ?? true { newest = (live.snapshot, date) }
    }
    return newest.flatMap(\.snapshot)
  }

  /// Registers a window's tabs for saving and saves them.
  /// - Parameters:
  ///   - window: The window's id.
  ///   - server: The server's URL.
  ///   - snapshot: Reads the window's tabs at write time.
  ///   - group: Reads one of the window's session groups, for other windows.
  public func register(
    window: UUID, server: String, snapshot: @escaping Provider,
    group: @escaping GroupProvider = { _ in nil }
  ) {
    let key = Self.key(server)
    claimed.insert(window)
    servers[key] = server
    providers[key, default: [:]][window] = snapshot
    groupProviders[key, default: [:]][window] = group
    scheduleSave(server: server)
  }

  /// Stops saving a window, after saving its tabs. Closing the window (`keepRecord` false) also
  /// drops its page; sessions keep their tabs either way.
  /// - Parameters:
  ///   - window: The window's id.
  ///   - server: The server's URL.
  ///   - keepRecord: Keep the window's page for the next launch.
  public func unregister(window: UUID, server: String, keepRecord: Bool) {
    let key = Self.key(server)
    write(key, server: server)
    providers[key]?[window] = nil
    groupProviders[key]?[window] = nil
    claimed.remove(window)
    if !keepRecord, var file = load(key, server: server) {
      file.windows.removeAll { $0.window == window }
      files[key] = file
      write(key, server: server)
    }
  }

  /// Forgets sessions' tabs: the sessions were archived or deleted.
  /// - Parameters:
  ///   - sessionIDs: The sessions.
  ///   - server: The server's URL.
  public func removeSessions(_ sessionIDs: Set<String>, server: String) {
    let key = Self.key(server)
    let now = Date()
    for id in sessionIDs { removedAt[id] = now }
    guard var file = load(key, server: server) else { return }
    let before = file.sessions.count
    for id in sessionIDs { file.sessions[id] = nil }
    files[key] = file
    if file.sessions.count != before { scheduleSave(server: server) }
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

  /// A window closed for good: saves its tabs, stops saving it and drops its page.
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
      let file = TabFile(version: Self.version, server: server)
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
      let state: TabWindowState
      do {
        state = try provider()
      } catch {
        report("Some tabs could not be saved: \(error.localizedDescription)", saving: true)
        complete = false
        continue
      }
      file.windows.removeAll { $0.window == window }
      file.windows.append(
        TabWindowRecord(
          window: window, launch: launch, savedAt: now,
          page: state.page.map(AppTabContent.init)))
      for (sessionID, group) in state.groups {
        merge(group, of: sessionID, into: &file, key: key)
      }
    }
    if file.sessions.count > Self.sessionLimit {
      let oldest = file.sessions.sorted { $0.value.savedAt > $1.value.savedAt }
        .dropFirst(Self.sessionLimit).map(\.key)
      for id in oldest { file.sessions[id] = nil }
    }
    file.version = Self.version
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

  /// Saves a window's group when it changed after the saved one; a group showing just its chat
  /// leaves no record.
  private func merge(
    _ group: TabGroupState, of sessionID: String, into file: inout TabFile, key: String
  ) {
    let merged = "\(key)/\(sessionID)"
    let newest = [file.sessions[sessionID]?.savedAt, removedAt[sessionID], mergedAt[merged]]
      .compactMap(\.self).max()
    guard let changedAt = group.changedAt, changedAt > newest ?? .distantPast else { return }
    mergedAt[merged] = changedAt
    if SessionTabGroups.isDefault(group.snapshot) {
      file.sessions[sessionID] = nil
    } else {
      file.sessions[sessionID] = TabGroupRecord(savedAt: changedAt, snapshot: group.snapshot)
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
