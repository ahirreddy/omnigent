public import Foundation

/// One back/forward entry.
nonisolated public struct BrowserNavigationEntry: Codable, Hashable, Sendable {
  /// The entry's URL.
  public var url: URL
  /// The entry's title, empty when unknown.
  public var title: String

  /// Creates an entry.
  public init(url: URL, title: String) {
    self.url = url
    self.title = title
  }
}

/// A tab's back/forward list, engine-neutral.
nonisolated public struct BrowserNavigationHistory: Codable, Hashable, Sendable {
  /// Entries, oldest first.
  public var entries: [BrowserNavigationEntry]
  /// The current entry's index.
  public var currentIndex: Int

  /// No entries.
  public static let empty = Self(entries: [], currentIndex: 0)
  /// Entries kept per tab when saving, around the current one (Chrome keeps 50).
  public static let maximumSavedEntries = 50

  /// Creates a list; `currentIndex` is clamped to the entries.
  public init(entries: [BrowserNavigationEntry], currentIndex: Int) {
    self.entries = entries
    self.currentIndex = entries.isEmpty ? 0 : min(max(0, currentIndex), entries.count - 1)
  }

  /// The current entry.
  public var current: BrowserNavigationEntry? {
    entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
  }

  /// The list as it should be saved: restore placeholders mapped back to their pages, blank
  /// entries dropped, and at most `maximumSavedEntries` entries around the current one.
  public func normalizedForSaving() -> Self {
    var kept: [BrowserNavigationEntry] = []
    var current = 0
    for (index, entry) in entries.enumerated() {
      let resolved = BrowserRestorePlaceholder.entry(from: entry.url) ?? entry
      guard BrowserRestorePlaceholder.isRestorable(resolved.url) else { continue }
      if index <= currentIndex { current = kept.count }
      kept.append(resolved)
    }
    guard kept.count > Self.maximumSavedEntries else {
      return Self(entries: kept, currentIndex: current)
    }
    let start = max(
      0, min(current - Self.maximumSavedEntries / 2, kept.count - Self.maximumSavedEntries))
    let window = Array(kept[start..<(start + Self.maximumSavedEntries)])
    return Self(entries: window, currentIndex: current - start)
  }
}

/// Rebuilds a back/forward list in an engine that cannot restore one natively (Chromium through
/// CEF, or WebKit without `interactionState`).
///
/// The tab loads `startURL` (an `about:blank` page), then `rebuildScript` adds one same-document
/// entry per saved page with `history.pushState`, each an `about:blank#omnigent-restore&u=…&t=…`
/// placeholder, moves to the current one and replaces it with the real page. When the user later
/// goes back or forward onto a placeholder, the engine loads `about:blank` with that fragment and
/// `replaceScript` swaps in the real page, so each entry loads only when it is visited. The
/// scripts run with a user gesture (Chromium's `Runtime.evaluate` sets one, WebKit's evaluation
/// is user-initiated), so Chromium's history-manipulation intervention does not skip the entries.
nonisolated public enum BrowserRestorePlaceholder {
  static let marker = "omnigent-restore"

  /// The page a rebuild starts from.
  public static let startURL = makeStartURL()

  /// The literal always parses; the fallback is unreachable.
  private static func makeStartURL() -> URL {
    URL(string: "about:blank#\(marker)") ?? URL(fileURLWithPath: "/")
  }

  /// Whether `url` is a placeholder or the start page.
  public static func isPlaceholder(_ url: URL?) -> Bool {
    guard let url, url.scheme == "about" else { return false }
    return url.fragment(percentEncoded: true)?.hasPrefix(marker) == true
  }

  /// The saved entry a placeholder stands for, or nil when `url` is not one.
  public static func entry(from url: URL) -> BrowserNavigationEntry? {
    guard isPlaceholder(url), let fragment = url.fragment(percentEncoded: true) else { return nil }
    var values: [String: String] = [:]
    for pair in fragment.dropFirst(marker.count).split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, let value = String(parts[1]).removingPercentEncoding else { continue }
      values[String(parts[0])] = value
    }
    guard let raw = values["u"], let target = URL(string: raw) else { return nil }
    return BrowserNavigationEntry(url: target, title: values["t"] ?? "")
  }

  /// Whether a saved entry is worth restoring (not blank pages or placeholders).
  public static func isRestorable(_ url: URL) -> Bool {
    !isPlaceholder(url) && url.absoluteString != "about:blank"
  }

  private static let unreserved = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

  /// The fragment (`#omnigent-restore&u=…&t=…`) for one entry, relative to `about:blank`.
  static func fragment(for entry: BrowserNavigationEntry) -> String {
    "#\(marker)&u=\(escape(entry.url.absoluteString))&t=\(escape(entry.title))"
  }

  /// Percent-encodes everything but unreserved characters, so values survive both
  /// `URLSearchParams` (which reads `+` as a space) and `removingPercentEncoding`.
  static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  /// Script that rebuilds `history` on the start page. Returns true.
  public static func rebuildScript(for history: BrowserNavigationHistory) throws(BrowserError)
    -> String
  {
    let json = try AgentBrowserScripts.jsonText(
      history.entries.map(fragment(for:)), of: "the history to restore")
    return """
      (() => {
        const entries = \(json);
        if (entries.length === 0) return false;
        const target = \(history.currentIndex);
        const finish = () => {
          const params = new URLSearchParams(location.hash.slice(\(marker.count + 2)));
          location.replace(params.get('u'));
        };
        history.replaceState(null, '', entries[0]);
        for (let i = 1; i < entries.length; i++) history.pushState(null, '', entries[i]);
        const delta = target - (entries.length - 1);
        if (delta === 0) { finish(); } else {
          addEventListener('popstate', finish, { once: true });
          history.go(delta);
        }
        return true;
      })()
      """
  }

  /// Script that replaces the placeholder the tab is on with its page. Returns whether it did.
  public static let replaceScript = """
    (() => {
      if (location.protocol !== 'about:' || !location.hash.startsWith('#\(marker)&')) return false;
      const target = new URLSearchParams(location.hash.slice(\(marker.count + 2))).get('u');
      if (!target) return false;
      location.replace(target);
      return true;
    })()
    """
}
