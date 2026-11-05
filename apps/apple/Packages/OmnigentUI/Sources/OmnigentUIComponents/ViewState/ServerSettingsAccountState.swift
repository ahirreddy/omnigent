public import Foundation

/// Who the caller is signed in as, for the Account pane.
nonisolated public struct ServerAccountState: Hashable, Sendable {
  /// The user id (a username or email).
  public var userID: String
  /// An administrator.
  public var isAdmin: Bool
  /// Password accounts: the caller can change their password here (an SSO password lives with
  /// the identity provider).
  public var canChangePassword: Bool

  /// Creates the account.
  /// - Parameters:
  ///   - userID: The user id.
  ///   - isAdmin: An administrator.
  ///   - canChangePassword: Password accounts.
  public init(userID: String, isAdmin: Bool = false, canChangePassword: Bool = false) {
    self.userID = userID
    self.isAdmin = isAdmin
    self.canChangePassword = canChangePassword
  }
}

/// What the Archived pane knows about an archived session beyond its summary.
nonisolated public struct ArchivedSessionInfo: Hashable, Sendable {
  /// The project it is filed in (``ServerSettingsViewState/archivedProjects`` ids).
  public var projectID: String?
  /// When it was archived, Unix seconds (its last change when the server does not say).
  public var archivedAt: Int64
  /// The caller owns it, so may delete it.
  public var canDelete: Bool

  /// Creates the facts.
  /// - Parameters:
  ///   - projectID: Its project.
  ///   - archivedAt: When it was archived.
  ///   - canDelete: The caller owns it.
  public init(projectID: String? = nil, archivedAt: Int64, canDelete: Bool) {
    self.projectID = projectID
    self.archivedAt = archivedAt
    self.canDelete = canDelete
  }
}

/// How long archived sessions stay before the Archived pane marks them expired: the web's
/// `omnigent:archived-retention-days` (whole days as text; absent for never).
nonisolated public enum ArchivedRetention {
  /// The device-local key.
  public static let key = "omnigent:archived-retention-days"
  /// The choices, `nil` for never.
  public static let choices: [Int?] = [nil, 7, 30, 60, 90]

  /// The stored days, or `nil` for never (also for a value the web would not write).
  /// - Parameter stored: The stored text.
  /// - Returns: Whole days, at least one.
  public static func days(_ stored: String?) -> Int? {
    guard let stored, let days = Int(stored), days > 0 else { return nil }
    return days
  }

  /// The choice's label.
  /// - Parameter days: Days, or `nil` for never.
  /// - Returns: The label.
  public static func title(_ days: Int?) -> String {
    days.map { "After \($0) days" } ?? "Never"
  }

  /// The sessions past `days` the caller may delete, in list order.
  /// - Parameters:
  ///   - sessions: Archived sessions.
  ///   - info: Their facts; a session without any is never expired.
  ///   - days: The retention, or `nil` for never.
  ///   - now: The current time.
  /// - Returns: Their ids.
  public static func expired(
    _ sessions: [SessionSummary], info: [String: ArchivedSessionInfo], days: Int?, now: Date
  ) -> [String] {
    guard let days else { return [] }
    let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 86_400
    return sessions.compactMap { session in
      guard let facts = info[session.id], facts.canDelete, facts.archivedAt < cutoff else {
        return nil
      }
      return session.id
    }
  }
}
