public import Foundation

/// What omnibox text means.
nonisolated public enum BrowserOmniboxInput: Hashable, Sendable {
  /// Navigate to a URL.
  case url(URL)
  /// Search for `query`; `url` is the results page.
  case search(query: String, url: URL)

  /// The URL to load.
  public var url: URL {
    switch self {
    case .url(let url): url
    case .search(_, let url): url
    }
  }
}

/// One row under the omnibox.
nonisolated public struct BrowserOmniboxSuggestion: Hashable, Identifiable, Sendable {
  /// Where a suggestion comes from.
  public enum Kind: Hashable, Sendable {
    /// Go to what was typed.
    case navigate
    /// Search for what was typed.
    case search
    /// A page from history.
    case history
    /// A bookmark.
    case bookmark
    /// A tab that is already open; selecting it switches to that tab.
    case openTab(UUID)
  }

  /// Identity.
  public var id: String { "\(kind)|\(url.absoluteString)" }
  /// The source.
  public let kind: Kind
  /// The main line.
  public let title: String
  /// The second line (usually the address).
  public let subtitle: String
  /// The page to open.
  public let url: URL
}

/// A tab the omnibox can offer to switch to.
nonisolated public struct BrowserOmniboxOpenTab: Hashable, Sendable {
  /// The tab's ID.
  public let id: UUID
  /// Its profile.
  public let profileID: UUID
  /// Its title.
  public let title: String
  /// Its URL.
  public let url: URL

  /// Creates a record.
  public init(id: UUID, profileID: UUID, title: String, url: URL) {
    self.id = id
    self.profileID = profileID
    self.title = title
    self.url = url
  }
}

/// Search-or-URL detection and suggestions, Chrome-style.
nonisolated public enum BrowserOmnibox {
  /// Schemes typed URLs may use. `javascript:` is never navigated from the omnibox.
  static let navigableSchemes: Set<String> = [
    "http", "https", "file", "about", "data", "view-source", "ftp", "mailto", "blob",
  ]
  /// Top-level domains that mean a local or development host, loaded over http.
  static let localTLDs: Set<String> = ["localhost", "local", "test", "internal", "lan", "home"]

  /// Interprets omnibox text as a URL when it looks like one, otherwise as a search. Nil for
  /// empty text.
  public static func interpret(_ text: String, searchEngine: BrowserSearchEngine)
    -> BrowserOmniboxInput?
  {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = likelyURL(trimmed) {
      return .url(url)
    }
    let query =
      trimmed.hasPrefix("?")
      ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
    guard !query.isEmpty, let url = searchEngine.url(for: query) else { return nil }
    return .search(query: query, url: url)
  }

  /// The URL `text` names, or nil when it reads as a search. A leading `?` forces a search.
  public static func likelyURL(_ text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("?") else { return nil }
    if let scheme = explicitScheme(trimmed) {
      if navigableSchemes.contains(scheme) {
        let candidate =
          trimmed.contains("://") ? trimmed.replacingOccurrences(of: " ", with: "%20") : trimmed
        guard !candidate.contains(where: \.isNewline), let url = URL(string: candidate) else {
          return nil
        }
        if ["http", "https", "ftp"].contains(scheme), url.host() == nil { return nil }
        return url
      }
      if scheme == "javascript" { return nil }
    }
    guard !trimmed.contains(where: \.isWhitespace), !trimmed.contains("@") || trimmed.contains("/")
    else {
      return nil
    }
    return hostURL(trimmed)
  }

  /// `host[:port][/path]` text as a URL: http for local and IP hosts, https otherwise.
  static func hostURL(_ text: String) -> URL? {
    guard let probe = URL(string: "http://\(text)"),
      let host = probe.host(percentEncoded: false)?
        .lowercased(), !host.isEmpty
    else {
      return nil
    }
    let scheme: String
    if host == "localhost" || host.hasSuffix(".localhost") || isIPv4(host) || host.contains(":") {
      scheme = "http"
    } else if host.contains(".") {
      let labels = host.split(separator: ".", omittingEmptySubsequences: false)
      guard labels.allSatisfy(isHostLabel), let tld = labels.last.map(String.init),
        tld.count >= 2, tld.allSatisfy(\.isLetter) || tld.hasPrefix("xn--")
      else {
        return nil
      }
      scheme = localTLDs.contains(tld) ? "http" : "https"
    } else if probe.port != nil, isHostLabel(Substring(host)) {
      scheme = "http"  // "devbox:8080"
    } else {
      return nil
    }
    return URL(string: "\(scheme)://\(text)")
  }

  /// Suggestions for `text`: what was typed (go or search), matching open tabs, bookmarks and
  /// history, without duplicate URLs.
  @MainActor public static func suggestions(
    for text: String, searchEngine: BrowserSearchEngine, history: BrowserHistoryStore?,
    bookmarks: BrowserBookmarkStore?, openTabs: [BrowserOmniboxOpenTab], limit: Int = 8
  ) -> [BrowserOmniboxSuggestion] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let input = interpret(trimmed, searchEngine: searchEngine) else { return [] }
    var results: [BrowserOmniboxSuggestion] = []
    var seen: Set<URL> = []
    func add(_ suggestion: BrowserOmniboxSuggestion) {
      guard results.count < limit, seen.insert(suggestion.url).inserted else { return }
      results.append(suggestion)
    }
    switch input {
    case .url(let url):
      add(
        BrowserOmniboxSuggestion(kind: .navigate, title: trimmed, subtitle: "Go to site", url: url))
    case .search(let query, let url):
      add(
        BrowserOmniboxSuggestion(
          kind: .search, title: query, subtitle: "\(searchEngine.name) Search", url: url))
    }
    let words = trimmed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    for tab in openTabs
    where words.allSatisfy({ word in
      tab.title.lowercased().contains(word) || tab.url.absoluteString.lowercased().contains(word)
    }) {
      add(
        BrowserOmniboxSuggestion(
          kind: .openTab(tab.id), title: tab.title.isEmpty ? tab.url.absoluteString : tab.title,
          subtitle: "Switch to tab", url: tab.url))
      if results.count >= 3 { break }
    }
    for bookmark in bookmarks?.search(trimmed, limit: 3) ?? [] {
      guard let url = bookmark.url else { continue }
      add(
        BrowserOmniboxSuggestion(
          kind: .bookmark, title: bookmark.title,
          subtitle: BrowserHistoryStore.displayAddress(url), url: url))
    }
    for entry in history?.search(trimmed, limit: limit) ?? [] {
      add(
        BrowserOmniboxSuggestion(
          kind: .history,
          title: entry.title.isEmpty ? BrowserHistoryStore.displayAddress(entry.url) : entry.title,
          subtitle: BrowserHistoryStore.displayAddress(entry.url), url: entry.url))
    }
    return results
  }

  private static func explicitScheme(_ text: String) -> String? {
    guard let colon = text.firstIndex(of: ":") else { return nil }
    let scheme = text[..<colon]
    guard let first = scheme.first, first.isLetter,
      scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) })
    else {
      return nil
    }
    // "localhost:3000" and "example.com:8080" have a port, not a scheme.
    let rest = text[text.index(after: colon)...]
    if !rest.hasPrefix("//"), let digit = rest.first, digit.isNumber { return nil }
    return scheme.lowercased()
  }

  private static func isIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4
      && parts.allSatisfy { part in
        !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
      }
  }

  private static func isHostLabel(_ label: Substring) -> Bool {
    !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
      && label.allSatisfy { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }
}
