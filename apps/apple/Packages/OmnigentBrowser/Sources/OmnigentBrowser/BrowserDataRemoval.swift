public import Foundation

/// Kinds of browsing data that "Clear Browsing Data" removes.
nonisolated public struct BrowserDataTypes: OptionSet, Sendable, Hashable, Codable {
  /// Raw bits.
  public let rawValue: Int

  /// Creates a set from raw bits.
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// Cookies (the engine's).
  public static let cookies = Self(rawValue: 1 << 0)
  /// Cached images and files (the engine's).
  public static let cache = Self(rawValue: 1 << 1)
  /// Local storage, IndexedDB, service workers and other site storage (the engine's).
  public static let siteData = Self(rawValue: 1 << 2)
  /// Browsing history (the app's).
  public static let history = Self(rawValue: 1 << 3)
  /// Remembered site permissions and zoom levels (the app's).
  public static let siteSettings = Self(rawValue: 1 << 4)
  /// The downloads list; files stay on disk (the app's).
  public static let downloads = Self(rawValue: 1 << 5)

  /// What engines store.
  public static let engineData: Self = [.cookies, .cache, .siteData]
  /// Everything.
  public static let all: Self = [.cookies, .cache, .siteData, .history, .siteSettings, .downloads]
}

extension BrowserEngineProvider {
  /// Removes engine data of `types` for `profile` from every offered engine, starting engines
  /// that are not running.
  public func removeData(
    _ types: BrowserDataTypes, for profile: BrowserProfile, since: Date?, origins: [URL]
  ) async throws(BrowserError) {
    for kind in offeredEngines where availability(of: kind).isAvailable {
      try await engine(for: kind).removeData(types, for: profile, since: since, origins: origins)
    }
  }

  /// Deletes all of a deleted profile's engine data from every offered engine.
  public func deleteProfileData(_ profile: BrowserProfile) async throws(BrowserError) {
    for kind in offeredEngines where availability(of: kind).isAvailable {
      try await engine(for: kind).deleteProfileData(profile)
    }
  }
}
