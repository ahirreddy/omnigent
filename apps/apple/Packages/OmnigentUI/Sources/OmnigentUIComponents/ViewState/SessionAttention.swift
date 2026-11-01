// Mirror of the core's attention model (`omnigent-core` `session_attention.rs`). The app passes
// the core's values; previews and the playground set them in sample data.

/// Why a session needs (or does not need) the user. Cases are in precedence order:
/// Needs you > Failed > Working > Unread > Idle.
nonisolated public enum SessionAttentionState: Int, Hashable, Sendable, CaseIterable, Comparable {
  /// Pending decisions the user can answer.
  case needsYou
  /// The last turn failed.
  case failed
  /// A turn or background work is in progress.
  case working
  /// Activity the user has not seen.
  case unread
  /// Nothing to show.
  case idle

  /// The state a list status implies, for summaries that carry no attention of their own.
  /// - Parameters:
  ///   - status: The list status.
  ///   - failure: The last failure, if any.
  public init(status: SessionListStatus, failure: String?) {
    switch status {
    case .needsResponse: self = .needsYou
    case .running: self = .working
    case .idle: self = failure == nil ? .idle : .failed
    }
  }

  /// A short label, for tooltips and accessibility.
  public var label: String {
    switch self {
    case .needsYou: "Needs you"
    case .failed: "Failed"
    case .working: "Running"
    case .unread: "Unread"
    case .idle: "Idle"
    }
  }

  /// Whether `lhs` is more urgent than `rhs`.
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
