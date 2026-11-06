import Foundation

/// One server's saved tabs: each session's group and each window's page. Format 1 saved whole
/// windows of tabs that spanned sessions; it is read by grouping them (``TabMigration``).
nonisolated struct TabFile: Codable, Sendable {
  var version: Int
  /// The server, for people reading the file.
  var server: String
  var windows: [TabWindowRecord]
  /// Each session's tabs, by session id; a session showing just its chat has none.
  var sessions: [String: TabGroupRecord]

  init(
    version: Int, server: String, windows: [TabWindowRecord] = [],
    sessions: [String: TabGroupRecord] = [:]
  ) {
    self.version = version
    self.server = server
    self.windows = windows
    self.sessions = sessions
  }

  private enum CodingKeys: String, CodingKey {
    case version, server, windows, sessions
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    server = try container.decode(String.self, forKey: .server)
    guard version >= 2 else {
      let legacy = try container.decode([LegacyWindowRecord].self, forKey: .windows)
      (windows, sessions) = TabMigration.migrate(legacy)
      return
    }
    windows = try container.decodeIfPresent([TabWindowRecord].self, forKey: .windows) ?? []
    sessions =
      try container.decodeIfPresent([String: TabGroupRecord].self, forKey: .sessions) ?? [:]
  }
}

/// One window's page: the session or session-less page it showed.
nonisolated struct TabWindowRecord: Codable, Sendable, Equatable {
  var window: UUID
  /// The launch that wrote it; records from this launch are never adopted by another window.
  var launch: UUID
  var savedAt: Date
  /// A session's chat for a session, else the page; `nil` for nothing.
  var page: AppTabContent?

}

/// One session's saved tabs.
nonisolated struct TabGroupRecord: Codable, Sendable {
  /// When the tabs last changed.
  var savedAt: Date
  var snapshot: TabWindowSnapshot
  /// Tabs that could not be decoded (a kind from a newer app), reported once on restore.
  var skipped: [String] = []

  init(savedAt: Date, snapshot: TabWindowSnapshot, skipped: [String] = []) {
    self.savedAt = savedAt
    self.snapshot = snapshot
    self.skipped = skipped
  }

  private enum CodingKeys: String, CodingKey {
    case savedAt
  }

  init(from decoder: any Decoder) throws {
    savedAt = try decoder.container(keyedBy: CodingKeys.self).decode(Date.self, forKey: .savedAt)
    (snapshot, skipped) = try LenientSnapshot.decode(from: decoder)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(savedAt, forKey: .savedAt)
    try LenientSnapshot.encode(snapshot, to: encoder)
  }
}

/// A format-1 window: its tabs across sessions.
nonisolated struct LegacyWindowRecord: Decodable, Sendable {
  var window: UUID
  var launch: UUID
  var savedAt: Date
  var snapshot: TabWindowSnapshot
  var skipped: [String] = []

  private enum CodingKeys: String, CodingKey {
    case window, launch, savedAt
  }

  init(window: UUID, launch: UUID, savedAt: Date, snapshot: TabWindowSnapshot) {
    self.window = window
    self.launch = launch
    self.savedAt = savedAt
    self.snapshot = snapshot
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    window = try container.decode(UUID.self, forKey: .window)
    launch = try container.decode(UUID.self, forKey: .launch)
    savedAt = try container.decode(Date.self, forKey: .savedAt)
    (snapshot, skipped) = try LenientSnapshot.decode(from: decoder)
  }
}

/// A snapshot's keys, decoded so that a tab or split view from a newer app is skipped with the
/// reason instead of losing the rest.
nonisolated enum LenientSnapshot {
  private enum CodingKeys: String, CodingKey {
    case selectedID, tabs, closed, split
  }

  static func decode(from decoder: any Decoder) throws -> (TabWindowSnapshot, [String]) {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let tabs = try container.decode([LenientTab].self, forKey: .tabs)
    let closed = try container.decodeIfPresent([LenientTab].self, forKey: .closed) ?? []
    let split = try container.decodeIfPresent(LenientSplit.self, forKey: .split)
    let snapshot = TabWindowSnapshot(
      tabs: tabs.compactMap(\.tab),
      selectedID: try container.decodeIfPresent(String.self, forKey: .selectedID),
      closed: closed.compactMap(\.tab), split: split?.split)
    return (snapshot, (tabs + closed).compactMap(\.problem) + [split?.problem].compactMap { $0 })
  }

  static func encode(_ snapshot: TabWindowSnapshot, to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(snapshot.tabs, forKey: .tabs)
    try container.encodeIfPresent(snapshot.selectedID, forKey: .selectedID)
    try container.encode(snapshot.closed, forKey: .closed)
    try container.encodeIfPresent(snapshot.split, forKey: .split)
  }
}

/// A split view that decodes to `nil` with the reason when it is from a newer layout version or
/// malformed, so the group still restores its tabs, in one pane.
nonisolated struct LenientSplit: Decodable {
  let split: TabSplitSnapshot?
  let problem: String?

  private enum CodingKeys: String, CodingKey {
    case version
  }

  init(from decoder: any Decoder) throws {
    do {
      let version = try decoder.container(keyedBy: CodingKeys.self)
        .decode(Int.self, forKey: .version)
      guard version <= TabSplitSnapshot.version else {
        split = nil
        problem = "the split view is from a newer version of the app"
        return
      }
      split = try TabSplitSnapshot(from: decoder)
      problem = nil
    } catch {
      split = nil
      problem = "the split view could not be read (\(error))"
    }
  }
}

/// A tab that decodes to `nil` with the reason when its kind is unknown, so one bad tab does
/// not lose the rest.
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
  static var tabs: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension JSONDecoder {
  static var tabs: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
