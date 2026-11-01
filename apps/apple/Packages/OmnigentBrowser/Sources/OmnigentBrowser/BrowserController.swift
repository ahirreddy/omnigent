public import Foundation
public import Observation

/// Owns the tab for one browser surface and handles engine selection and failure.
///
/// The controller never swaps engines on its own. If the preferred engine cannot start, the
/// content becomes `.engineUnavailable` until the user picks another engine.
@Observable
public final class BrowserController {
  /// What the browser surface should display.
  public enum Content {
    /// Not activated yet.
    case idle
    /// A live tab.
    case tab(any BrowserTab)
    /// The requested engine could not provide a tab.
    case engineUnavailable(requested: BrowserEngineKind, error: BrowserError)
  }

  /// Engine preference shared with settings.
  public let preferences: BrowserPreferences
  /// Storage profile for every tab this controller creates.
  public let profile: BrowserProfile
  @ObservationIgnored private let provider: any BrowserEngineProvider
  /// Answers the prompts, popups and downloads of this controller's tabs.
  public let presenter: BrowserPromptPresenter

  /// Current content.
  public private(set) var content: Content = .idle
  /// The URL to restore when a tab is (re)created.
  public private(set) var requestedURL: URL?
  /// Gives a new tab its first content instead of loading `requestedURL` (session restore,
  /// carrying history across an engine switch). Called after the tab is installed.
  @ObservationIgnored public var prepareTab: ((any BrowserTab) -> Void)?
  /// Called with the tab an engine switch or retry is about to close.
  @ObservationIgnored public var willReplaceTab: ((any BrowserTab) -> Void)?

  /// Creates a controller. Call `activate()` to create the first tab.
  public init(
    profile: BrowserProfile,
    preferences: BrowserPreferences,
    provider: any BrowserEngineProvider,
    initialURL: URL?,
    presenter: BrowserPromptPresenter = .shared
  ) {
    self.profile = profile
    self.preferences = preferences
    self.provider = provider
    self.presenter = presenter
    requestedURL = initialURL
  }

  /// Wraps a tab that already exists, such as a popup a page opened.
  public init(
    adopting tab: any BrowserTab, preferences: BrowserPreferences,
    provider: any BrowserEngineProvider, presenter: BrowserPromptPresenter = .shared
  ) {
    profile = tab.profile
    self.preferences = preferences
    self.provider = provider
    self.presenter = presenter
    requestedURL = tab.state.url
    tab.delegate = presenter
    content = .tab(tab)
  }

  /// Opens a popup the policy blocked, in a new tab without an opener.
  public func openBlockedPopup(_ popup: BrowserBlockedPopup) {
    guard let opener = tab, let url = popup.url else { return }
    opener.state.dismissBlockedPopup()
    do {
      let engine = try provider.engine(for: opener.engineKind)
      let newTab = try engine.makeTab(profile: profile, initialURL: url)
      newTab.popupPolicy = opener.popupPolicy
      presenter.tab(
        opener,
        didOpen: BrowserPopup(
          tab: newTab, opener: opener, targetURL: url, disposition: .foregroundTab,
          requestedSize: nil))
    } catch {
      opener.state.report(error)
    }
  }

  /// The live tab, if any.
  public var tab: (any BrowserTab)? {
    if case .tab(let tab) = content { return tab }
    return nil
  }

  /// The engine of the live tab, or the one that failed.
  public var activeEngine: BrowserEngineKind? {
    switch content {
    case .idle: nil
    case .tab(let tab): tab.engineKind
    case .engineUnavailable(let requested, _): requested
    }
  }

  /// Availability of an engine, for pickers and settings.
  public func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability {
    provider.availability(of: kind)
  }

  /// Engines this build offers, in display order.
  public var offeredEngines: [BrowserEngineKind] { provider.offeredEngines }

  /// Creates a tab for the preferred engine if none matches it yet.
  public func activate() {
    let wanted = preferences.engine
    if activeEngine == wanted, case .tab = content {
      return
    }
    replaceTab(with: wanted)
  }

  /// Persists `kind` as the preferred engine and rebuilds the tab at the current URL.
  public func switchEngine(to kind: BrowserEngineKind) {
    preferences.engine = kind
    replaceTab(with: kind)
  }

  /// Retries the preferred engine after a failure.
  public func retry() {
    replaceTab(with: preferences.engine)
  }

  /// Loads `url` in the live tab, or remembers it for the next tab.
  public func load(_ url: URL) {
    requestedURL = url
    tab?.load(url)
  }

  /// Parses user input from an address field and loads it.
  /// - Throws: `BrowserError.invalidURL` when the text cannot be a URL.
  public func load(addressText: String) throws(BrowserError) {
    load(try Self.url(fromAddressText: addressText))
  }

  /// Closes the live tab.
  public func close() {
    tab?.close()
    content = .idle
  }

  /// Turns address-bar text into a URL, adding `https://` when no scheme is given.
  public nonisolated static func url(fromAddressText text: String) throws(BrowserError) -> URL {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(" ") else {
      throw .invalidURL(text)
    }
    let candidate =
      trimmed.contains("://") || trimmed.hasPrefix("about:")
        || trimmed.hasPrefix("data:") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate), url.scheme != nil else {
      throw .invalidURL(text)
    }
    return url
  }

  private func replaceTab(with kind: BrowserEngineKind) {
    if let current = tab {
      willReplaceTab?(current)
      if let url = current.state.url {
        requestedURL = url
      }
      current.close()
    }
    do {
      let engine = try provider.engine(for: kind)
      let newTab = try engine.makeTab(
        profile: profile, initialURL: prepareTab == nil ? requestedURL : nil)
      newTab.delegate = presenter
      content = .tab(newTab)
      prepareTab?(newTab)
    } catch {
      content = .engineUnavailable(requested: kind, error: error)
    }
  }
}
