public import Foundation

/// A Browser design tool request (Annotate, Draw) on its way to the session, as the composer
/// lists it above the field, like its queued messages.
nonisolated public struct DesignRequestRow: Hashable, Sendable, Identifiable {
  /// The tool that made it.
  public enum Tool: Hashable, Sendable {
    /// A picked element and what should change.
    case annotate
    /// A marked-up screenshot.
    case draw

    /// The tool's SF Symbol, as the browser's toolbar shows it.
    public var systemImage: String {
      switch self {
      case .annotate: "cursorarrow.click.2"
      case .draw: "pencil.and.scribble"
      }
    }
  }

  /// Where it stands.
  public enum State: Hashable, Sendable {
    /// Waiting for the session's turn to end.
    case waiting
    /// On its way.
    case sending
    /// Not sent, with why; `canRetry` is false for one a policy blocked.
    case failed(String, canRetry: Bool)
  }

  /// Identity.
  public var id: UUID
  /// The tool.
  public var tool: Tool
  /// A one-line name (`Annotate p "Hello"`).
  public var label: String
  /// Where it stands.
  public var state: State

  /// Creates a row.
  /// - Parameters:
  ///   - id: Identity.
  ///   - tool: The tool.
  ///   - label: Its name.
  ///   - state: Where it stands.
  public init(id: UUID, tool: Tool, label: String, state: State) {
    self.id = id
    self.tool = tool
    self.label = label
    self.state = state
  }
}

/// What the composer's design request rows do.
public struct DesignRequestActions {
  /// Sends a failed request again.
  public var retry: @MainActor (UUID) -> Void
  /// Drops a request that isn't on its way.
  public var remove: @MainActor (UUID) -> Void

  /// Creates the actions.
  /// - Parameters:
  ///   - retry: Sends a failed request again.
  ///   - remove: Drops a request.
  public init(
    retry: @escaping @MainActor (UUID) -> Void, remove: @escaping @MainActor (UUID) -> Void
  ) {
    self.retry = retry
    self.remove = remove
  }
}
