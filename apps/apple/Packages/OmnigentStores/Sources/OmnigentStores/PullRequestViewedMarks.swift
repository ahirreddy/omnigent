public import Foundation
public import Observation
import OmnigentWorkspaceUI

/// The server and signed-in user a device keeps viewed marks under.
nonisolated public struct PullRequestViewedScope: Hashable, Sendable {
  /// The server's address.
  public var server: String
  /// The signed-in user (`local` on a single-user server).
  public var user: String

  /// Creates a scope.
  /// - Parameters:
  ///   - server: The server's address.
  ///   - user: The user.
  public init(server: String, user: String) {
    self.server = server
    self.user = user
  }
}

/// A pull request as viewed marks name it: provider, host, repository and number.
nonisolated public struct PullRequestViewedIdentity: Hashable, Sendable {
  /// The provider's id.
  public var provider: String
  /// The forge host.
  public var host: String
  /// `owner/name`.
  public var repository: String
  /// The number.
  public var number: UInt64

  /// Creates an identity.
  /// - Parameters:
  ///   - provider: The provider's id; empty reads as GitHub.
  ///   - host: The forge host.
  ///   - repository: `owner/name`.
  ///   - number: The number.
  public init(provider: String, host: String, repository: String, number: UInt64) {
    self.provider = provider.isEmpty ? "github" : provider
    self.host = host
    self.repository = repository
    self.number = number
  }
}

/// Which files of a pull request are viewed, and which changed since they were.
nonisolated public struct PullRequestViewedState: Equatable, Sendable {
  /// Marked files whose hunks match a fingerprint they were viewed at.
  public var viewed: Set<String> = []
  /// Marked files whose hunks match none of them.
  public var changed: Set<String> = []

  /// Nothing viewed.
  public init() {}
}

/// Viewed marks for pull request files, kept on this device as the web keeps them in the
/// browser: per server, user and pull request, each file with the hunk fingerprints it was
/// viewed at, so a file stays viewed on a new head while its hunks are the same.
@Observable
public final class PullRequestViewedMarks {
  /// The app's marks.
  public static let shared = PullRequestViewedMarks(defaults: .standard)

  /// Entries past this age are dropped.
  static let maxAge: TimeInterval = 90 * 24 * 60 * 60
  /// At most this many pull requests keep marks.
  static let maxEntries = 500
  /// At most this many fingerprints per file.
  static let maxFingerprints = 3
  static let storageKey = "omnigent.pullRequestViewed.v2"

  private let defaults: UserDefaults
  private let now: @MainActor () -> Date
  /// Bumped on every write, so readers redraw.
  private(set) var version = 0

  /// Marks kept in `defaults`.
  /// - Parameters:
  ///   - defaults: Where they are stored.
  ///   - now: The clock, for ages.
  public init(defaults: UserDefaults, now: @escaping @MainActor () -> Date = { Date() }) {
    self.defaults = defaults
    self.now = now
  }

  private struct Entry: Codable {
    var marks: [String: [String]]
    var updatedAt: TimeInterval
  }

  /// The key of one pull request's marks.
  static func key(_ scope: PullRequestViewedScope, _ pullRequest: PullRequestViewedIdentity)
    -> String
  {
    let parts: [String] = [
      scope.server, scope.user, pullRequest.provider, pullRequest.host.lowercased(),
      pullRequest.repository.lowercased(),
      String(pullRequest.number),
    ]
    return parts.map { $0.replacingOccurrences(of: "\u{1}", with: "") }
      .joined(separator: "\u{1}")
  }

  private func entries() -> [String: Entry] {
    guard let data = defaults.data(forKey: Self.storageKey) else { return [:] }
    do {
      return try JSONDecoder().decode([String: Entry].self, from: data)
    } catch {
      // Unreadable marks are dropped; the next write replaces them.
      return [:]
    }
  }

  /// Which of a pull request's files are viewed and changed, given each file's fingerprint now.
  /// - Parameters:
  ///   - scope: Server and user.
  ///   - pullRequest: The pull request.
  ///   - fingerprint: Each file's current fingerprint.
  /// - Returns: The state.
  public func state(
    _ scope: PullRequestViewedScope, _ pullRequest: PullRequestViewedIdentity,
    fingerprint: (String) -> String
  ) -> PullRequestViewedState {
    _ = version
    var state = PullRequestViewedState()
    for (path, prints) in entries()[Self.key(scope, pullRequest)]?.marks ?? [:] {
      let current = fingerprint(path)
      if prints.contains(current) {
        state.viewed.insert(path)
      } else if DiffFingerprint.isVerified(current),
        prints.contains(where: DiffFingerprint.isVerified)
      {
        state.changed.insert(path)
      }
    }
    return state
  }

  /// Marks `paths` viewed at their current fingerprints, or unmarks them (forgetting every
  /// fingerprint).
  /// - Parameters:
  ///   - paths: The files.
  ///   - viewed: Mark or unmark.
  ///   - scope: Server and user.
  ///   - pullRequest: The pull request.
  ///   - fingerprint: Each file's current fingerprint.
  public func set(
    _ paths: [String], viewed: Bool, _ scope: PullRequestViewedScope,
    _ pullRequest: PullRequestViewedIdentity, fingerprint: (String) -> String
  ) {
    var all = entries()
    let key = Self.key(scope, pullRequest)
    var marks = all[key]?.marks ?? [:]
    for path in paths {
      if !viewed {
        marks[path] = nil
        continue
      }
      let print = fingerprint(path)
      let kept = marks[path] ?? []
      guard !kept.contains(print) else { continue }
      marks[path] = Array(
        (kept.filter(DiffFingerprint.isVerified) + [print]).suffix(Self.maxFingerprints))
    }
    let stamp = now().timeIntervalSince1970
    all[key] = Entry(marks: marks, updatedAt: stamp)
    let kept = all.filter { $0.key == key || stamp - $0.value.updatedAt <= Self.maxAge }
      .sorted { $0.value.updatedAt > $1.value.updatedAt }
      .prefix(Self.maxEntries)
    do {
      let data = try JSONEncoder().encode(
        Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) }))
      defaults.set(data, forKey: Self.storageKey)
    } catch {
      // Encoding plain strings and numbers cannot fail; nothing is stored if it does.
      return
    }
    version += 1
  }
}
