import Foundation
import Observation

/// Servers the user connected to, most recent first, persisted in `UserDefaults`.
///
/// Deep links to these open without a consent prompt, and Settings offers them as the default
/// server for new windows.
@Observable
final class RecentServers {
  /// `UserDefaults` key holding the URL strings.
  static let defaultsKey = "omnigent.recentServers"
  /// How many servers are kept.
  static let limit = 10

  /// The servers, most recent first.
  private(set) var urls: [URL]
  /// Stored entries that were not URLs, so the caller can report them.
  private(set) var rejectedEntries: [String] = []
  @ObservationIgnored private let defaults: UserDefaults

  /// Loads the list.
  /// - Parameter defaults: The store; tests pass a private suite.
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    var urls: [URL] = []
    var rejected: [String] = []
    for entry in defaults.stringArray(forKey: Self.defaultsKey) ?? [] {
      if let url = URL(string: entry), url.scheme != nil {
        urls.append(url)
      } else {
        rejected.append(entry)
      }
    }
    self.urls = urls
    rejectedEntries = rejected
  }

  /// Moves `url` to the front, dropping duplicates and the oldest entries past `limit`.
  /// - Parameter url: The server.
  func record(_ url: URL) {
    var updated = [url]
    updated.append(contentsOf: urls.filter { $0 != url })
    urls = Array(updated.prefix(Self.limit))
    defaults.set(urls.map(\.absoluteString), forKey: Self.defaultsKey)
  }
}

extension RecentServers {
  /// Removes `url` from the list.
  /// - Parameter url: The server, as listed.
  func forget(_ url: URL) {
    urls.removeAll { $0 == url }
    defaults.set(urls.map(\.absoluteString), forKey: Self.defaultsKey)
  }
}
