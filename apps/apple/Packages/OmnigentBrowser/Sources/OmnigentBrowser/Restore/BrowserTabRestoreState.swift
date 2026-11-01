public import Foundation
public import Observation

/// Everything needed to bring a browser tab back after a relaunch, a crash or "reopen closed
/// tab". Codable, so the tab system stores it with its other tab kinds.
nonisolated public struct BrowserTabRestoreState: Codable, Hashable, Sendable, Identifiable {
  /// The version this build writes. Newer versions fail to decode with
  /// `BrowserError.restoreStateUnsupported`.
  public static let currentVersion = 1

  /// Format version.
  public var version: Int
  /// The tab's stable ID.
  public var id: UUID
  /// The tab's profile.
  public var profileID: UUID
  /// The current page.
  public var url: URL?
  /// The current page's title.
  public var title: String
  /// The page icon, as a 32-pixel PNG.
  public var faviconPNG: Data?
  /// The back/forward list.
  public var history: BrowserNavigationHistory
  /// WebKit's `interactionState` (history plus scroll positions); used when restoring into
  /// WebKit.
  public var webKitInteractionState: Data?
  /// Whether the tab is pinned (owned by the tab strip).
  public var isPinned: Bool
  /// Whether the tab is muted.
  public var isMuted: Bool

  /// Creates a state.
  public init(
    id: UUID = UUID(), profileID: UUID, url: URL?, title: String = "", faviconPNG: Data? = nil,
    history: BrowserNavigationHistory = .empty, webKitInteractionState: Data? = nil,
    isPinned: Bool = false, isMuted: Bool = false
  ) {
    version = Self.currentVersion
    self.id = id
    self.profileID = profileID
    self.url = url
    self.title = title
    self.faviconPNG = faviconPNG
    self.history = history
    self.webKitInteractionState = webKitInteractionState
    self.isPinned = isPinned
    self.isMuted = isMuted
  }

  enum CodingKeys: String, CodingKey {
    case version, id, profileID, url, title, faviconPNG, history, webKitInteractionState,
      isPinned, isMuted
  }

  /// Decodes a state, rejecting versions newer than this build understands.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    guard version <= Self.currentVersion else {
      throw BrowserError.restoreStateUnsupported(version: version)
    }
    id = try container.decode(UUID.self, forKey: .id)
    profileID = try container.decode(UUID.self, forKey: .profileID)
    url = try container.decodeIfPresent(URL.self, forKey: .url)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
    faviconPNG = try container.decodeIfPresent(Data.self, forKey: .faviconPNG)
    history =
      try container.decodeIfPresent(BrowserNavigationHistory.self, forKey: .history) ?? .empty
    webKitInteractionState = try container.decodeIfPresent(
      Data.self, forKey: .webKitInteractionState)
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
  }

  /// The history to rebuild: the saved list, or just the current page.
  var effectiveHistory: BrowserNavigationHistory {
    let saved = history.normalizedForSaving()
    if !saved.entries.isEmpty { return saved }
    guard let url, BrowserRestorePlaceholder.isRestorable(url) else { return .empty }
    return BrowserNavigationHistory(
      entries: [BrowserNavigationEntry(url: url, title: title)], currentIndex: 0)
  }
}

/// A window's browser tabs, for apps (and the proof app) that persist browser tabs on their own.
nonisolated public struct BrowserSessionSnapshot: Codable, Hashable, Sendable {
  /// The tabs, in strip order.
  public var tabs: [BrowserTabRestoreState]
  /// The selected tab.
  public var selectedTabID: UUID?

  /// Creates a snapshot.
  public init(tabs: [BrowserTabRestoreState], selectedTabID: UUID?) {
    self.tabs = tabs
    self.selectedTabID = selectedTabID
  }
}

/// Recently closed browser tabs, newest last, for "Reopen Closed Tab". Persisted (debounced)
/// so the list survives relaunch.
@Observable
public final class BrowserRecentlyClosedStore {
  /// Tabs kept.
  public static let capacity = 25

  /// Closed tabs, oldest first.
  public private(set) var states: [BrowserTabRestoreState]
  /// The most recent load or save failure.
  public private(set) var lastError: BrowserError?
  @ObservationIgnored private let file: BrowserPersistentFile<[BrowserTabRestoreState]>?

  /// Loads from `fileURL`, or keeps the list in memory when nil.
  public init(fileURL: URL?) {
    file = fileURL.map {
      BrowserPersistentFile(url: $0, version: BrowserTabRestoreState.currentVersion)
    }
    let (loaded, error) = file?.loadMovingAsideIfDamaged() ?? (nil, nil)
    states = loaded ?? []
    lastError = error
    file?.onError = { [weak self] error in self?.lastError = error }
  }

  /// Remembers a closed tab.
  public func push(_ state: BrowserTabRestoreState) {
    states.removeAll { $0.id == state.id }
    states.append(state)
    if states.count > Self.capacity { states.removeFirst(states.count - Self.capacity) }
    file?.schedule(states)
  }

  /// Takes the most recently closed tab.
  public func popLast() -> BrowserTabRestoreState? {
    guard let state = states.popLast() else { return nil }
    file?.schedule(states)
    return state
  }

  /// Drops closed tabs of a profile (when it is deleted).
  public func removeAll(profileID: UUID) {
    states.removeAll { $0.profileID == profileID }
    file?.schedule(states)
  }

  /// Writes pending changes.
  public func flush() throws(BrowserError) {
    try file?.flush()
  }
}
