public import Foundation
public import Observation

/// One visit to a page.
nonisolated public struct BrowserHistoryVisit: Codable, Hashable, Identifiable, Sendable {
  /// Identity.
  public let id: UUID
  /// The page.
  public let url: URL
  /// Its title at the time, updated when the page reports one.
  public var title: String
  /// When.
  public let date: Date
  /// Whether the user typed or pasted the URL.
  public var typed: Bool

  /// Creates a visit.
  public init(id: UUID = UUID(), url: URL, title: String, date: Date, typed: Bool = false) {
    self.id = id
    self.url = url
    self.title = title
    self.date = date
    self.typed = typed
  }
}

/// A page's visits rolled up, for omnibox suggestions.
nonisolated public struct BrowserHistoryEntry: Hashable, Identifiable, Sendable {
  /// The page's URL; also the identity.
  public var id: URL { url }
  /// The page.
  public let url: URL
  /// The latest title.
  public var title: String
  /// Visits.
  public var visitCount: Int
  /// Typed visits.
  public var typedCount: Int
  /// The latest visit.
  public var lastVisit: Date

  /// Ranking by frequency and recency (higher is better).
  public func frecency(now: Date) -> Double {
    let days = max(0, now.timeIntervalSince(lastVisit) / 86_400)
    return Double(visitCount + typedCount * 2) / (1 + days / 7)
  }
}

/// One profile's browsing history, newest first. Persisted to `history.json` (debounced) unless
/// the store is in memory.
@Observable
public final class BrowserHistoryStore {
  /// Visits kept; older ones are dropped.
  public static let maximumVisits = 20_000
  /// The file format version.
  public static let fileVersion = 1

  /// Every visit, newest first.
  public private(set) var visits: [BrowserHistoryVisit] = []
  /// The most recent load or save failure.
  public private(set) var lastError: BrowserError?

  @ObservationIgnored private let file: BrowserPersistentFile<[BrowserHistoryVisit]>?
  @ObservationIgnored private var entriesByURL: [URL: BrowserHistoryEntry] = [:]

  /// Loads history from `fileURL`, or keeps it in memory when nil. A damaged file is moved aside
  /// and reported in `lastError`.
  public init(fileURL: URL?) {
    file = fileURL.map { BrowserPersistentFile(url: $0, version: Self.fileVersion) }
    if let file {
      let (loaded, error) = file.loadMovingAsideIfDamaged()
      visits = loaded ?? []
      lastError = error
      file.onError = { [weak self] error in self?.lastError = error }
    }
    rebuildEntries()
  }

  /// Whether `url` belongs in history.
  nonisolated public static func isRecordable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return ["http", "https", "file"].contains(scheme)
  }

  /// Records a visit. Repeats of the newest visit within 30 seconds (reloads, redirects back)
  /// update it instead of adding one.
  public func recordVisit(url: URL, title: String, typed: Bool = false, at date: Date = Date()) {
    guard Self.isRecordable(url) else { return }
    if let newest = visits.first, newest.url == url, date.timeIntervalSince(newest.date) < 30 {
      if !title.isEmpty { visits[0].title = title }
      visits[0].typed = visits[0].typed || typed
    } else {
      visits.insert(BrowserHistoryVisit(url: url, title: title, date: date, typed: typed), at: 0)
      if visits.count > Self.maximumVisits { visits.removeLast(visits.count - Self.maximumVisits) }
      var entry =
        entriesByURL[url]
        ?? BrowserHistoryEntry(
          url: url, title: title, visitCount: 0, typedCount: 0, lastVisit: date)
      entry.visitCount += 1
      entry.typedCount += typed ? 1 : 0
      entry.lastVisit = date
      if !title.isEmpty { entry.title = title }
      entriesByURL[url] = entry
    }
    save()
  }

  /// Sets the title of the newest visit to `url`, once the page reports it.
  public func updateTitle(_ title: String, for url: URL) {
    guard !title.isEmpty, let index = visits.firstIndex(where: { $0.url == url }),
      visits[index].title != title
    else {
      return
    }
    visits[index].title = title
    entriesByURL[url]?.title = title
    save()
  }

  /// Pages whose URL or title contains every word of `text`, best first. Host prefix matches
  /// rank above other matches.
  public func search(_ text: String, limit: Int = 8, now: Date = Date()) -> [BrowserHistoryEntry] {
    let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }
    let scored = entriesByURL.values.compactMap { entry -> (BrowserHistoryEntry, Double)? in
      let address = Self.displayAddress(entry.url).lowercased()
      let title = entry.title.lowercased()
      guard words.allSatisfy({ address.contains($0) || title.contains($0) }) else { return nil }
      let prefix =
        address.hasPrefix(words[0]) || address.hasPrefix("www.\(words[0])") ? 3.0 : 1.0
      return (entry, entry.frecency(now: now) * prefix)
    }
    return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
  }

  /// Visits whose URL or title contains `query` (all when empty), newest first.
  public func visits(matching query: String) -> [BrowserHistoryVisit] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return visits }
    return visits.filter {
      $0.url.absoluteString.lowercased().contains(needle) || $0.title.lowercased().contains(needle)
    }
  }

  /// Removes visits.
  public func remove(visitIDs: Set<UUID>) {
    visits.removeAll { visitIDs.contains($0.id) }
    rebuildEntries()
    save()
  }

  /// Removes every visit since `date`, or all history when nil.
  public func removeAll(since date: Date?) {
    if let date {
      visits.removeAll { $0.date >= date }
    } else {
      visits.removeAll()
    }
    rebuildEntries()
    save()
  }

  /// Distinct `scheme://host[:port]` origins in history, for clearing site data per site.
  public var origins: [URL] {
    var seen: Set<String> = []
    var result: [URL] = []
    for url in entriesByURL.keys {
      guard let scheme = url.scheme, let host = url.host(percentEncoded: false) else { continue }
      let origin = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
      if seen.insert(origin).inserted, let originURL = URL(string: origin) {
        result.append(originURL)
      }
    }
    return result
  }

  /// Writes pending changes now.
  public func flush() throws(BrowserError) {
    try file?.flush()
  }

  /// `host/path` without the scheme or a trailing slash.
  nonisolated public static func displayAddress(_ url: URL) -> String {
    var text = url.absoluteString
    for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
      text.removeFirst(prefix.count)
    }
    if text.hasSuffix("/") { text.removeLast() }
    return text
  }

  private func rebuildEntries() {
    entriesByURL = [:]
    for visit in visits.reversed() {
      var entry =
        entriesByURL[visit.url]
        ?? BrowserHistoryEntry(
          url: visit.url, title: visit.title, visitCount: 0, typedCount: 0, lastVisit: visit.date)
      entry.visitCount += 1
      entry.typedCount += visit.typed ? 1 : 0
      entry.lastVisit = visit.date
      if !visit.title.isEmpty { entry.title = visit.title }
      entriesByURL[visit.url] = entry
    }
  }

  private func save() {
    file?.schedule(visits)
  }
}
