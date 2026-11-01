public import Foundation
public import Observation
internal import os

/// Find-in-page state for one tab.
@Observable
public final class BrowserFindModel {
  /// Whether the find bar shows.
  public var isVisible = false
  /// The text searched for.
  public var query = ""
  /// Whether matching is case-sensitive.
  public var caseSensitive = false
  /// The latest result.
  public internal(set) var result: BrowserFindResult?
  /// Increments when the find field should take focus.
  public internal(set) var focusRequest = 0

  /// Creates hidden find state.
  public init() {}
}

/// One browser tab as the app's tab strip hosts it: profile, title, favicon, URL, loading,
/// audio and history state, its engine tab (created lazily), and Codable restore state.
/// Create models with `BrowserEnvironment.makeTab` or `restoreTab`.
@Observable
public final class BrowserTabModel: Identifiable {
  /// Stable identity, kept across restore.
  public let id: UUID
  /// The tab's profile.
  public let profileID: UUID
  /// The engine storage identity of the profile.
  public let browserProfile: BrowserProfile
  /// Engine selection and the live engine tab.
  public let controller: BrowserController
  /// Find-in-page state.
  public let find = BrowserFindModel()
  /// Whether the tab is pinned. The tab strip owns its meaning; it is saved with the tab.
  public var isPinned: Bool {
    didSet { bumpRevision() }
  }
  /// Whether the engine tab exists (the content view has appeared once).
  public private(set) var isActivated = false
  /// Whether `close()` was called.
  public private(set) var isClosed = false
  /// Whether the tab is muted.
  public internal(set) var isMuted: Bool
  /// The page icon.
  public internal(set) var favicon: BrowserFavicon?
  /// Increments whenever `snapshotForRestore()` would return something different.
  public internal(set) var restoreRevision = 0
  /// The latest failure of a tab command (print, bookmark, DevTools, restore). Page load
  /// errors are in `pageError`.
  public internal(set) var lastError: BrowserError?
  /// Increments when the omnibox should take focus (new tab, ⌘L).
  public internal(set) var omniboxFocusRequest = 0
  /// Why the page icon could not be loaded, if it could not.
  public internal(set) var faviconError: BrowserError?

  @ObservationIgnored let environment: BrowserEnvironment
  /// Saved state shown until the engine tab has rebuilt it.
  @ObservationIgnored var pending: BrowserTabRestoreState?
  @ObservationIgnored var restore = RestoreProgress.idle
  @ObservationIgnored var lastRecordedURL: URL?
  @ObservationIgnored var nextVisitTyped = false
  @ObservationIgnored var lastZoomHost: String?
  @ObservationIgnored var lastFaviconURL: URL?
  @ObservationIgnored var lastReplacedPlaceholder: URL?
  @ObservationIgnored var signature = ""
  @ObservationIgnored var skipSnapshotOnReplace = false

  enum RestoreProgress {
    case idle
    case loadingStart(BrowserNavigationHistory)
    case rebuilding(BrowserNavigationHistory)
    case done
  }

  init(
    environment: BrowserEnvironment, id: UUID, profileID: UUID, url: URL?,
    restoring state: BrowserTabRestoreState?
  ) {
    self.environment = environment
    self.id = id
    self.profileID = profileID
    browserProfile = Self.storageProfile(profileID, in: environment)
    isPinned = state?.isPinned ?? false
    isMuted = state?.isMuted ?? false
    pending = state
    favicon = state?.faviconPNG.map(BrowserFavicon.init(pngData:))
    controller = BrowserController(
      profile: browserProfile, preferences: environment.preferences, provider: environment.provider,
      initialURL: state == nil ? url : nil, presenter: environment.presenter)
    installHooks()
    if state == nil, url == nil { omniboxFocusRequest = 1 }
  }

  /// Wraps a tab a page opened (popup, target=_blank, "Open Link in New Tab").
  init(environment: BrowserEnvironment, profileID: UUID, adopting tab: any BrowserTab) {
    self.environment = environment
    id = UUID()
    self.profileID = profileID
    browserProfile = tab.profile
    isPinned = false
    isMuted = false
    controller = BrowserController(
      adopting: tab, preferences: environment.preferences, provider: environment.provider,
      presenter: environment.presenter)
    isActivated = true
    restore = .done
    installHooks()
    observe(tab)
  }

  private static func storageProfile(_ id: UUID, in environment: BrowserEnvironment)
    -> BrowserProfile
  {
    environment.profiles.profile(id: id)?.browserProfile
      ?? BrowserUserProfile(id: id, name: "", color: .gray).browserProfile
  }

  func installHooks() {
    controller.prepareTab = { [weak self] tab in self?.prepare(tab) }
    controller.willReplaceTab = { [weak self] tab in
      guard let self, !self.skipSnapshotOnReplace else { return }
      self.pending = self.snapshot(of: tab)
    }
  }

  // MARK: Display state

  /// The live engine tab.
  public var tab: (any BrowserTab)? { controller.tab }
  /// The tab's profile, nil when it was deleted.
  public var profile: BrowserUserProfile? { environment.profiles.profile(id: profileID) }
  /// The engine showing the tab, once activated.
  public var engineKind: BrowserEngineKind? { controller.activeEngine }

  /// The current page; restore placeholders are mapped to the page they stand for.
  public var url: URL? {
    guard let state = tab?.state else { return pending?.url ?? controller.requestedURL }
    if let url = state.url, BrowserRestorePlaceholder.isPlaceholder(url) {
      return BrowserRestorePlaceholder.entry(from: url)?.url ?? pending?.url
    }
    return state.url ?? pending?.url ?? controller.requestedURL
  }

  /// The page title.
  public var title: String {
    guard let state = tab?.state else { return pending?.title ?? "" }
    if let url = state.url, BrowserRestorePlaceholder.isPlaceholder(url) {
      return BrowserRestorePlaceholder.entry(from: url)?.title ?? pending?.title ?? ""
    }
    return state.title
  }

  /// The title, or the host, or "New Tab".
  public var displayTitle: String {
    if !title.isEmpty { return title }
    if let host = url?.host(percentEncoded: false) { return host }
    if let url, url.absoluteString != "about:blank" { return url.absoluteString }
    return "New Tab"
  }

  /// Whether the page is loading (restoring counts).
  public var isLoading: Bool {
    if case .loadingStart = restore { return true }
    if case .rebuilding = restore { return true }
    return tab?.state.isLoading ?? false
  }
  /// Load progress in `0...1`.
  public var estimatedProgress: Double { tab?.state.estimatedProgress ?? 0 }
  /// Whether Back works.
  public var canGoBack: Bool {
    guard let state = tab?.state else { return (pending?.effectiveHistory.currentIndex ?? 0) > 0 }
    return state.canGoBack
  }
  /// Whether Forward works.
  public var canGoForward: Bool {
    guard let state = tab?.state else {
      let history = pending?.effectiveHistory ?? .empty
      return history.currentIndex < history.entries.count - 1
    }
    return state.canGoForward
  }
  /// Whether the page plays media with sound.
  public var isAudible: Bool { tab?.state.isAudible ?? false }
  /// Page zoom; 1 is 100%.
  public var zoomFactor: Double {
    tab?.state.zoomFactor ?? environment.zoom(for: profileID).factor(for: url)
  }
  /// The page's latest load error.
  public var pageError: BrowserError? { tab?.state.lastError }
  /// Whether the page is bookmarked in this profile.
  public var isBookmarked: Bool {
    guard let url else { return false }
    return environment.bookmarks(for: profileID).isBookmarked(url)
  }

  // MARK: Lifecycle

  /// Creates the engine tab on first call, restoring saved history; later calls switch to the
  /// preferred engine if it changed.
  public func activate() {
    guard !isClosed else { return }
    isActivated = true
    controller.activate()
  }

  /// Closes the engine tab, records the tab in `environment.recentlyClosed` and returns its
  /// restore state.
  @discardableResult
  public func close() -> BrowserTabRestoreState {
    let state = snapshotForRestore()
    guard !isClosed else { return state }
    isClosed = true
    controller.close()
    environment.didClose(self, state: state)
    return state
  }

  // MARK: Restore

  /// The tab's state for saving. Before activation it is the state the tab was restored from.
  public func snapshotForRestore() -> BrowserTabRestoreState {
    var state: BrowserTabRestoreState
    if let tab, case .done = restore {
      state = snapshot(of: tab)
    } else if var saved = pending {
      saved.isPinned = isPinned
      saved.isMuted = isMuted
      state = saved
    } else {
      let url = controller.requestedURL
      state = BrowserTabRestoreState(
        id: id, profileID: profileID, url: url,
        history: url.map {
          BrowserNavigationHistory(
            entries: [BrowserNavigationEntry(url: $0, title: "")], currentIndex: 0)
        } ?? .empty)
    }
    state.isPinned = isPinned
    state.isMuted = isMuted
    return state
  }

  /// Replaces the tab's content with `state` (its history, mute and pin). Loads at once when
  /// the tab is active, otherwise on activation.
  public func restore(from state: BrowserTabRestoreState) {
    pending = state
    isMuted = state.isMuted
    isPinned = state.isPinned
    favicon = state.faviconPNG.map(BrowserFavicon.init(pngData:))
    restore = .idle
    if tab != nil {
      skipSnapshotOnReplace = true
      controller.retry()
      skipSnapshotOnReplace = false
    }
    bumpRevision()
  }

  func snapshot(of tab: any BrowserTab) -> BrowserTabRestoreState {
    let history = tab.navigationHistory.normalizedForSaving()
    return BrowserTabRestoreState(
      id: id, profileID: profileID, url: url, title: title, faviconPNG: favicon?.pngData,
      history: history,
      webKitInteractionState: tab.engineKind == .system ? tab.engineRestoreData : nil,
      isPinned: isPinned, isMuted: isMuted)
  }

}

extension Logger {
  static let tabs = Logger(subsystem: "ai.omnigent.browser", category: "tabs")
}
