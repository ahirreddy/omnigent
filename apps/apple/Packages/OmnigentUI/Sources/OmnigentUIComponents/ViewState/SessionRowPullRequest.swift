public import Foundation

/// The PR a row's tooltip names, as the server last stored it.
nonisolated public struct SessionRowPullRequest: Hashable, Sendable {
  /// Its number.
  public var number: UInt64
  /// "Open", "Draft", "Merged" or "Closed"; `nil` before its host fetched it.
  public var status: String?
  /// When its host last fetched it.
  public var checkedAt: Date?

  /// Creates a PR.
  public init(number: UInt64, status: String? = nil, checkedAt: Date? = nil) {
    self.number = number
    self.status = status
    self.checkedAt = checkedAt
  }
}
