public import CoreGraphics
public import Foundation
public import Observation
internal import os

#if os(macOS)
  internal import AppKit
#endif

/// Why the browser asks the tab system to open a tab.
public struct BrowserTabOpenContext {
  /// Where the page (or the user) wanted it.
  public let disposition: BrowserPopupDisposition
  /// The tab it came from.
  public let opener: BrowserTabModel?
  /// The size a page asked for, for popup windows.
  public let requestedSize: CGSize?
}

/// Everything browser tabs share: profiles, settings, the prompt presenter, and each profile's
/// history, bookmarks and zoom. One per app. See INTEGRATION.md.
@Observable
public final class BrowserEnvironment {
  /// Where the browser's files live; nil keeps everything in memory (tests, previews).
  public let directory: URL?
  /// The engines this edition ships.
  @ObservationIgnored public let provider: any BrowserEngineProvider
  /// The persisted engine choice.
  public let preferences: BrowserPreferences
  /// Dialogs, permissions, downloads and certificate interstitials for every tab.
  public let presenter: BrowserPromptPresenter
  /// Search engine, bookmarks bar and new-tab settings.
  public let settings: BrowserSettings
  /// The user's profiles.
  public let profiles: BrowserProfileStore
  /// Closed tabs for "Reopen Closed Tab".
  public let recentlyClosed: BrowserRecentlyClosedStore
  /// Opens a tab the browser asks for (popups, links, view source). The model is created;
  /// insert it into the tab strip. Without a handler, page popups open in their own window.
  @ObservationIgnored public var onOpenTab: ((BrowserTabModel, BrowserTabOpenContext) -> Void)?
  /// Selects an open tab (the omnibox's "Switch to tab").
  @ObservationIgnored public var onSwitchToTab: ((UUID) -> Void)?
  /// Closes a tab whose page called `window.close()`. Without a handler the model just closes.
  @ObservationIgnored public var onCloseTab: ((BrowserTabModel) -> Void)?

  @ObservationIgnored let faviconLoader = BrowserFaviconLoader()
  @ObservationIgnored private var historyStores: [UUID: BrowserHistoryStore] = [:]
  @ObservationIgnored private var bookmarkStores: [UUID: BrowserBookmarkStore] = [:]
  @ObservationIgnored private var zoomStores: [UUID: BrowserZoomStore] = [:]
  @ObservationIgnored private let models = NSHashTable<BrowserTabModel>.weakObjects()
  @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

  /// Creates an environment.
  /// - Parameters:
  ///   - directory: Where profiles, history, bookmarks and zoom are saved; nil for memory only.
  ///   - provider: The engines.
  ///   - preferences: The engine choice.
  ///   - presenter: The prompt presenter; a new one by default, sharing the app's downloads list
  ///     and permission store.
  ///   - defaults: Where settings live.
  public init(
    directory: URL?, provider: any BrowserEngineProvider, preferences: BrowserPreferences,
    presenter: BrowserPromptPresenter = BrowserPromptPresenter(), defaults: UserDefaults = .standard
  ) {
    self.directory = directory
    self.provider = provider
    self.preferences = preferences
    self.presenter = presenter
    settings = BrowserSettings(defaults: defaults)
    profiles = BrowserProfileStore(
      fileURL: (directory
        ?? FileManager.default.temporaryDirectory.appending(
          path: "omnigent-browser-\(UUID().uuidString)")).appending(path: "profiles.json"))
    recentlyClosed = BrowserRecentlyClosedStore(
      fileURL: directory?.appending(path: "recently-closed.json"))
    profiles.cleanUp = { [weak self] profile throws(BrowserError) in
      try await self?.deleteData(of: profile)
    }
    presenter.onOpenPopup = { [weak self] popup in self?.open(popup) }
    #if os(macOS)
      terminationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.flushLogging() }
      }
    #endif
  }

  /// `Application Support/<bundle id>/Browser`.
  public static var standardDirectory: URL {
    let bundle = Bundle.main.bundleIdentifier ?? "ai.omnigent"
    return URL.applicationSupportDirectory.appending(
      path: "\(bundle)/Browser", directoryHint: .isDirectory)
  }

  // MARK: Per-profile stores

  /// A profile's history.
  public func history(for profileID: UUID) -> BrowserHistoryStore {
    if let store = historyStores[profileID] { return store }
    let store = BrowserHistoryStore(fileURL: profileFile(profileID, "history.json"))
    historyStores[profileID] = store
    return store
  }

  /// A profile's bookmarks.
  public func bookmarks(for profileID: UUID) -> BrowserBookmarkStore {
    if let store = bookmarkStores[profileID] { return store }
    let store = BrowserBookmarkStore(fileURL: profileFile(profileID, "bookmarks.json"))
    bookmarkStores[profileID] = store
    return store
  }

  /// A profile's per-site zoom.
  public func zoom(for profileID: UUID) -> BrowserZoomStore {
    if let store = zoomStores[profileID] { return store }
    let store = BrowserZoomStore(fileURL: profileFile(profileID, "zoom.json"))
    zoomStores[profileID] = store
    return store
  }

  private func profileDirectory(_ profileID: UUID) -> URL? {
    directory?.appending(path: "Profiles/\(profileID.uuidString)", directoryHint: .isDirectory)
  }

  private func profileFile(_ profileID: UUID, _ name: String) -> URL? {
    profileDirectory(profileID)?.appending(path: name)
  }

  // MARK: Tabs

  /// Every open tab model.
  public var liveTabs: [BrowserTabModel] {
    models.allObjects.filter { !$0.isClosed }
  }

  /// A new tab in `profileID` (the default profile when nil) at `url` (`settings.newTabURL`
  /// when nil). It loads when its content view first appears.
  public func makeTab(profileID: UUID? = nil, url: URL? = nil) -> BrowserTabModel {
    let model = BrowserTabModel(
      environment: self, id: UUID(), profileID: resolvedProfileID(profileID),
      url: url ?? settings.newTabURL, restoring: nil)
    models.add(model)
    return model
  }

  /// A tab from saved state. It shows the saved title and icon at once and rebuilds its
  /// history when its content view first appears. A deleted profile falls back to the default.
  public func restoreTab(_ state: BrowserTabRestoreState) -> BrowserTabModel {
    var state = state
    state.profileID = resolvedProfileID(state.profileID)
    let model = BrowserTabModel(
      environment: self, id: state.id, profileID: state.profileID, url: state.url,
      restoring: state)
    models.add(model)
    return model
  }

  /// Restores the most recently closed tab, or nil when there is none. Insert it in the strip.
  public func reopenClosedTab() -> BrowserTabModel? {
    recentlyClosed.popLast().map(restoreTab)
  }

  /// Opens `url` (the new-tab page when nil) in a new tab of `profileID` through `onOpenTab`.
  @discardableResult
  public func openTab(
    url: URL?, profileID: UUID, opener: BrowserTabModel?,
    disposition: BrowserPopupDisposition = .foregroundTab
  ) -> BrowserTabModel {
    let model = makeTab(profileID: profileID, url: url)
    if let onOpenTab {
      onOpenTab(
        model, BrowserTabOpenContext(disposition: disposition, opener: opener, requestedSize: nil))
    } else {
      Logger.tabs.error(
        "No tab strip handles new tabs; \(url?.absoluteString ?? "a new tab", privacy: .public) stays unopened."
      )
      opener?.lastError = .notAllowed("This window cannot open new tabs.")
    }
    return model
  }

  /// Tabs the omnibox can switch to.
  public func openTabSummaries(excluding id: UUID? = nil) -> [BrowserOmniboxOpenTab] {
    liveTabs.compactMap { model in
      guard model.id != id, let url = model.url, BrowserHistoryStore.isRecordable(url) else {
        return nil
      }
      return BrowserOmniboxOpenTab(
        id: model.id, profileID: model.profileID, title: model.title, url: url)
    }
  }

  func didClose(_ model: BrowserTabModel, state: BrowserTabRestoreState) {
    models.remove(model)
    if state.url != nil { recentlyClosed.push(state) }
  }

  func pageClosed(_ model: BrowserTabModel) {
    if let onCloseTab {
      onCloseTab(model)
    } else {
      model.close()
    }
  }

  private func open(_ popup: BrowserPopup) {
    let opener = liveTabs.first { $0.tab === popup.opener }
    guard let onOpenTab else {
      #if os(macOS)
        presenter.openInWindow(popup)
      #else
        if let url = popup.targetURL { popup.opener.load(url) }
        popup.tab.close()
      #endif
      return
    }
    let profileID =
      opener?.profileID ?? profiles.profile(for: popup.tab.profile)?.id ?? profiles.defaultProfileID
    let model = BrowserTabModel(environment: self, profileID: profileID, adopting: popup.tab)
    models.add(model)
    onOpenTab(
      model,
      BrowserTabOpenContext(
        disposition: popup.disposition, opener: opener, requestedSize: popup.requestedSize))
  }

  private func resolvedProfileID(_ id: UUID?) -> UUID {
    guard let id, profiles.profile(id: id) != nil else { return profiles.defaultProfileID }
    return id
  }

  // MARK: Data

  /// Clears `types` of one profile's data changed since `since` (nil: all time). Site settings
  /// and the downloads list are cleared for all time.
  public func clearBrowsingData(
    profileID: UUID, types: BrowserDataTypes, since: Date?
  ) async throws(BrowserError) {
    guard let profile = profiles.profile(id: profileID) else { throw .profileNotFound(profileID) }
    let history = history(for: profileID)
    let origins = history.origins
    if types.contains(.history) {
      history.removeAll(since: since)
      try history.flush()
      recentlyClosed.removeAll(profileID: profileID)
    }
    if types.contains(.siteSettings) {
      presenter.permissionStore.reset(profile: profile.browserProfile)
      zoom(for: profileID).removeAll()
      try zoom(for: profileID).flush()
    }
    if types.contains(.downloads) {
      presenter.downloadCenter.clearFinished(profileIdentifier: profile.browserProfile.identifier)
    }
    if !types.isDisjoint(with: .engineData) {
      try await provider.removeData(
        types.intersection(.engineData), for: profile.browserProfile, since: since,
        origins: origins)
    }
  }

  private func deleteData(of profile: BrowserUserProfile) async throws(BrowserError) {
    for model in liveTabs where model.profileID == profile.id {
      if let onCloseTab { onCloseTab(model) } else { model.close() }
    }
    historyStores[profile.id] = nil
    bookmarkStores[profile.id] = nil
    zoomStores[profile.id] = nil
    recentlyClosed.removeAll(profileID: profile.id)
    presenter.permissionStore.reset(profile: profile.browserProfile)
    if let folder = profileDirectory(profile.id),
      FileManager.default.fileExists(atPath: folder.path)
    {
      do {
        try FileManager.default.removeItem(at: folder)
      } catch {
        throw .storageFailed("Could not delete \(folder.path): \(error.localizedDescription)")
      }
    }
    try await provider.deleteProfileData(profile.browserProfile)
  }

  /// Writes every pending history, zoom and closed-tab change.
  public func flush() throws(BrowserError) {
    for store in historyStores.values { try store.flush() }
    for store in zoomStores.values { try store.flush() }
    try recentlyClosed.flush()
  }

  private func flushLogging() {
    do {
      try flush()
    } catch {
      Logger.tabs.error(
        "Saving browser data at quit failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
