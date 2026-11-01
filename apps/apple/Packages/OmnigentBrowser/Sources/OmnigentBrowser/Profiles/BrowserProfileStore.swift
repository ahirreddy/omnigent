public import Foundation
public import Observation

/// A profile color, Chrome-style. Rendered with the system's adaptive colors.
nonisolated public enum BrowserProfileColor: String, Codable, CaseIterable, Sendable, Hashable {
  case blue, purple, pink, red, orange, yellow, green, teal, gray
}

/// What a profile's avatar shows.
nonisolated public enum BrowserProfileAvatar: Codable, Hashable, Sendable {
  /// The first letters of the name.
  case initials
  /// An SF Symbol name.
  case symbol(String)
  /// One emoji.
  case emoji(String)

  /// Symbols offered by the avatar picker.
  public static let symbols = [
    "person.fill", "briefcase.fill", "house.fill", "graduationcap.fill", "flask.fill",
    "gamecontroller.fill", "airplane", "heart.fill", "star.fill", "leaf.fill", "pawprint.fill",
    "hammer.fill",
  ]
}

/// A named, persistent browser profile: its own cookies, storage, cache, history, bookmarks,
/// zoom levels and permissions.
nonisolated public struct BrowserUserProfile: Codable, Hashable, Identifiable, Sendable {
  /// Prefix of every user profile's storage identifier. Agent profiles never use it.
  public static let identifierPrefix = "user:"

  /// Stable identity.
  public let id: UUID
  /// Display name.
  public var name: String
  /// Accent color.
  public var color: BrowserProfileColor
  /// Avatar.
  public var avatar: BrowserProfileAvatar
  /// When it was created.
  public let createdAt: Date

  /// Creates a profile.
  public init(
    id: UUID = UUID(), name: String, color: BrowserProfileColor,
    avatar: BrowserProfileAvatar = .initials, createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.color = color
    self.avatar = avatar
    self.createdAt = createdAt
  }

  /// The engine storage identity: Chromium's `Profile-<key>` request context, WebKit's
  /// `WKWebsiteDataStore(forIdentifier:)`.
  public var browserProfile: BrowserProfile {
    BrowserProfile(
      identifier: Self.identifierPrefix + id.uuidString.lowercased(), persistence: .persistent)
  }

  /// Up to two initials of the name.
  public var initials: String {
    let words = name.split(whereSeparator: \.isWhitespace)
    let letters = words.prefix(2).compactMap(\.first).map(String.init)
    return letters.isEmpty ? "?" : letters.joined().uppercased()
  }

  /// Whether `profile` belongs to a user profile.
  public static func isUserProfile(_ profile: BrowserProfile) -> Bool {
    profile.identifier.hasPrefix(identifierPrefix)
  }
}

/// The user's browser profiles and which one new tabs use. Persisted in `profiles.json`.
@Observable
public final class BrowserProfileStore {
  /// Profiles in display order.
  public private(set) var profiles: [BrowserUserProfile]
  /// The profile new tabs and windows use unless one is picked.
  public private(set) var defaultProfileID: UUID
  /// The most recent load or save failure.
  public private(set) var lastError: BrowserError?

  @ObservationIgnored private let file: BrowserPersistentFile<Snapshot>
  /// Removes a deleted profile's data (history, bookmarks, engine storage). Set by
  /// `BrowserEnvironment`.
  @ObservationIgnored var cleanUp: ((BrowserUserProfile) async throws(BrowserError) -> Void)?

  struct Snapshot: Codable {
    var defaultProfileID: UUID
    var profiles: [BrowserUserProfile]
  }

  /// The file format version.
  public static let fileVersion = 1

  /// Loads profiles from `fileURL`, creating a "Personal" profile when there are none. A damaged
  /// file is moved aside and reported in `lastError`.
  public init(fileURL: URL) {
    file = BrowserPersistentFile(url: fileURL, version: Self.fileVersion)
    let (snapshot, error) = file.loadMovingAsideIfDamaged()
    lastError = error
    if let snapshot, !snapshot.profiles.isEmpty {
      profiles = snapshot.profiles
      defaultProfileID =
        snapshot.profiles.contains { $0.id == snapshot.defaultProfileID }
        ? snapshot.defaultProfileID : snapshot.profiles[0].id
    } else {
      let personal = BrowserUserProfile(name: "Personal", color: .blue)
      profiles = [personal]
      defaultProfileID = personal.id
      do {
        try file.write(Snapshot(defaultProfileID: personal.id, profiles: [personal]))
      } catch {
        lastError = error  // Shown by the profile manager; the next change retries.
      }
    }
  }

  /// The default profile.
  public var defaultProfile: BrowserUserProfile {
    profile(id: defaultProfileID) ?? profiles[0]
  }

  /// The profile with `id`.
  public func profile(id: UUID) -> BrowserUserProfile? {
    profiles.first { $0.id == id }
  }

  /// The profile whose storage identity is `profile`.
  public func profile(for profile: BrowserProfile) -> BrowserUserProfile? {
    profiles.first { $0.browserProfile == profile }
  }

  /// Adds a profile.
  @discardableResult
  public func create(
    name: String, color: BrowserProfileColor, avatar: BrowserProfileAvatar = .initials
  ) throws(BrowserError) -> BrowserUserProfile {
    let profile = BrowserUserProfile(name: try Self.validName(name), color: color, avatar: avatar)
    profiles.append(profile)
    try saveOrThrow()
    return profile
  }

  /// Saves a renamed, recolored or re-avatared profile.
  public func update(_ profile: BrowserUserProfile) throws(BrowserError) {
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
      throw .profileNotFound(profile.id)
    }
    var updated = profile
    updated.name = try Self.validName(profile.name)
    profiles[index] = updated
    try saveOrThrow()
  }

  /// Makes `id` the default profile.
  public func setDefault(_ id: UUID) throws(BrowserError) {
    guard profile(id: id) != nil else { throw .profileNotFound(id) }
    defaultProfileID = id
    try saveOrThrow()
  }

  /// Reorders profiles.
  public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws(BrowserError) {
    let moving = source.map { profiles[$0] }
    var remaining = profiles.enumerated().filter { !source.contains($0.offset) }.map(\.element)
    let insertAt = destination - source.filter { $0 < destination }.count
    remaining.insert(contentsOf: moving, at: min(max(0, insertAt), remaining.count))
    profiles = remaining
    try saveOrThrow()
  }

  /// Deletes a profile and all its data. The last profile cannot be deleted. When the default
  /// is deleted, the first remaining profile becomes the default.
  public func delete(id: UUID) async throws(BrowserError) {
    guard let profile = profile(id: id) else { throw .profileNotFound(id) }
    guard profiles.count > 1 else {
      throw .profileInvalid("The last profile cannot be deleted.")
    }
    profiles.removeAll { $0.id == id }
    if defaultProfileID == id { defaultProfileID = profiles[0].id }
    try saveOrThrow()
    try await cleanUp?(profile)
  }

  private static func validName(_ name: String) throws(BrowserError) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .profileInvalid("A profile needs a name.") }
    return String(trimmed.prefix(60))
  }

  private func saveOrThrow() throws(BrowserError) {
    do {
      try file.write(Snapshot(defaultProfileID: defaultProfileID, profiles: profiles))
      lastError = nil
    } catch {
      lastError = error
      throw error
    }
  }
}
