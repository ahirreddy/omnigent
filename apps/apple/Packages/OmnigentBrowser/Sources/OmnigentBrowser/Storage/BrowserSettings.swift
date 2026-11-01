public import Foundation
public import Observation

/// A search engine the omnibox sends queries to. `template` holds `%s` where the query goes.
nonisolated public struct BrowserSearchEngine: Codable, Hashable, Identifiable, Sendable {
  /// Stable identity ("google", "custom", ...).
  public let id: String
  /// Display name.
  public let name: String
  /// The search URL with `%s` for the query.
  public let template: String

  /// Creates an engine.
  public init(id: String, name: String, template: String) {
    self.id = id
    self.name = name
    self.template = template
  }

  /// Google.
  public static let google = Self(
    id: "google", name: "Google", template: "https://www.google.com/search?q=%s")
  /// DuckDuckGo.
  public static let duckDuckGo = Self(
    id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s")
  /// Bing.
  public static let bing = Self(
    id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s")
  /// Brave Search.
  public static let brave = Self(
    id: "brave", name: "Brave Search", template: "https://search.brave.com/search?q=%s")
  /// Kagi.
  public static let kagi = Self(id: "kagi", name: "Kagi", template: "https://kagi.com/search?q=%s")
  /// Ecosia.
  public static let ecosia = Self(
    id: "ecosia", name: "Ecosia", template: "https://www.ecosia.org/search?q=%s")

  /// The built-in engines, in picker order.
  public static let builtIn = [google, duckDuckGo, bing, brave, kagi, ecosia]

  /// Whether `template` is a usable search URL: http(s) with exactly one `%s`.
  public static func isValidTemplate(_ template: String) -> Bool {
    guard template.components(separatedBy: "%s").count == 2,
      let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")),
      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      url.host() != nil
    else {
      return false
    }
    return true
  }

  /// The results URL for `query`.
  public func url(for query: String) -> URL? {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#/")
    let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
  }
}

/// Browser settings shared by every profile, persisted in `UserDefaults`.
@Observable
public final class BrowserSettings {
  static let searchEngineKey = "ai.omnigent.browser.searchEngine"
  static let customTemplateKey = "ai.omnigent.browser.searchEngine.customTemplate"
  static let bookmarksBarKey = "ai.omnigent.browser.showsBookmarksBar"
  static let newTabURLKey = "ai.omnigent.browser.newTabURL"

  @ObservationIgnored private let defaults: UserDefaults

  /// The chosen engine's ID: one of `BrowserSearchEngine.builtIn`, or "custom".
  public var searchEngineID: String {
    didSet { defaults.set(searchEngineID, forKey: Self.searchEngineKey) }
  }
  /// The custom engine's template, used when `searchEngineID` is "custom".
  public var customSearchTemplate: String {
    didSet { defaults.set(customSearchTemplate, forKey: Self.customTemplateKey) }
  }
  /// Whether the bookmarks bar shows under the toolbar.
  public var showsBookmarksBar: Bool {
    didSet { defaults.set(showsBookmarksBar, forKey: Self.bookmarksBarKey) }
  }
  /// What new tabs open; nil shows an empty page with the omnibox focused.
  public var newTabURL: URL? {
    didSet { defaults.set(newTabURL?.absoluteString, forKey: Self.newTabURLKey) }
  }

  /// Reads settings from `defaults`.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    searchEngineID = defaults.string(forKey: Self.searchEngineKey) ?? BrowserSearchEngine.google.id
    customSearchTemplate = defaults.string(forKey: Self.customTemplateKey) ?? ""
    showsBookmarksBar = defaults.object(forKey: Self.bookmarksBarKey) as? Bool ?? true
    newTabURL = defaults.string(forKey: Self.newTabURLKey).flatMap(URL.init(string:))
  }

  /// The engine queries go to. An invalid custom template falls back to Google.
  public var searchEngine: BrowserSearchEngine {
    if searchEngineID == "custom", BrowserSearchEngine.isValidTemplate(customSearchTemplate) {
      return BrowserSearchEngine(id: "custom", name: "Custom", template: customSearchTemplate)
    }
    return BrowserSearchEngine.builtIn.first { $0.id == searchEngineID } ?? .google
  }
}

/// Per-site zoom for one profile, keyed by host, like Chrome. Persisted to `zoom.json`.
@Observable
public final class BrowserZoomStore {
  /// The zoom steps Chrome offers.
  public static let levels: [Double] = [
    0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5,
  ]

  /// Zoom by host; hosts at 100% are absent.
  public private(set) var factors: [String: Double]
  /// The most recent load or save failure.
  public private(set) var lastError: BrowserError?
  @ObservationIgnored private let file: BrowserPersistentFile<[String: Double]>?

  /// Loads from `fileURL`, or keeps zoom in memory when nil.
  public init(fileURL: URL?) {
    file = fileURL.map { BrowserPersistentFile(url: $0, version: 1) }
    let (loaded, error) = file?.loadMovingAsideIfDamaged() ?? (nil, nil)
    factors = loaded ?? [:]
    lastError = error
    file?.onError = { [weak self] error in self?.lastError = error }
  }

  /// The zoom for `url`'s host, 1 when none is stored.
  public func factor(for url: URL?) -> Double {
    guard let host = url?.host(percentEncoded: false)?.lowercased() else { return 1 }
    return factors[host] ?? 1
  }

  /// Remembers `factor` for `url`'s host.
  public func setFactor(_ factor: Double, for url: URL?) {
    guard let host = url?.host(percentEncoded: false)?.lowercased() else { return }
    factors[host] = abs(factor - 1) < 0.001 ? nil : factor
    file?.schedule(factors)
  }

  /// Forgets every site's zoom.
  public func removeAll() {
    factors = [:]
    file?.schedule(factors)
  }

  /// Writes pending changes.
  public func flush() throws(BrowserError) {
    try file?.flush()
  }

  /// The next step above (or below) `factor`.
  public static func step(from factor: Double, upward: Bool) -> Double {
    if upward {
      return levels.first { $0 > factor + 0.001 } ?? levels[levels.count - 1]
    }
    return levels.last { $0 < factor - 0.001 } ?? levels[0]
  }
}
