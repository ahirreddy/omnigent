import Foundation
public import OmnigentCoreFFI

extension CoreError {
  /// The core's user-facing text for this failure. It never carries a credential.
  public var message: String {
    switch self {
    case .InvalidUrl(let message), .Decode(let message), .Watch(let message),
      .Sync(let message), .ConfigurationRead(let message), .RowOps(let message),
      .Settings(let message), .DeepLink(let message), .Notification(let message),
      .Entropy(let message), .Attachment(let message), .InvalidState(let message):
      return message
    case .Transport(_, let message):
      return "Could not reach the server: \(message)"
    case .HttpStatus(let status, let body):
      let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
      return snippet.isEmpty
        ? "Server responded with HTTP \(status)"
        : "Server responded with HTTP \(status): \(snippet)"
    case .Session(_, let message, _, _, _), .Auth(_, _, let message, _),
      .Oidc(_, _, let message), .Link(_, let message, _),
      .ManagedConfig(let message, _, _), .SecureStore(let message, _),
      .Workspace(_, let message, _), .Terminal(_, let message, _),
      .RemoteBrowser(_, let message, _):
      return message
    case .Databricks(let kind, let message, _):
      return message.isEmpty && kind == .cancelled ? "Sign-in was cancelled." : message
    }
  }

  /// Whether the user must sign in again.
  public var requiresSignIn: Bool {
    switch self {
    case .Session(_, _, _, let requiresSignIn, _), .Link(_, _, let requiresSignIn),
      .Workspace(_, _, let requiresSignIn), .Terminal(_, _, let requiresSignIn),
      .RemoteBrowser(_, _, let requiresSignIn), .Databricks(_, _, let requiresSignIn):
      return requiresSignIn
    case .Auth(_, let failure, _, _), .Oidc(_, let failure, _):
      return failure == .signInRequired || failure == .expired
    default:
      return false
    }
  }

  /// Whether this is a cancellation the user caused, which shows no message.
  public var isCancellation: Bool {
    if case .Databricks(.cancelled, _, _) = self { return true }
    if case .Oidc(.cancelled, _, _) = self { return true }
    return false
  }

  /// Whether a write may have landed; the user must review before sending again.
  public var isDeliveryUncertain: Bool {
    if case .Session(_, _, _, _, let deliveryUncertain) = self { return deliveryUncertain }
    return false
  }
}

/// Converts anything a core call throws into a ``CoreError``, keeping unexpected errors visible.
func coreError(_ error: any Error) -> CoreError {
  if let error = error as? CoreError { return error }
  return .InvalidState(message: String(describing: error))
}

/// One failure surfaced as state, with where it happened.
public struct CoreIssue: Identifiable, Equatable, Sendable {
  /// Unique within the process.
  public let id: Int
  /// Where it happened.
  public let scope: ErrorScope
  /// The failure.
  public let error: CoreError
}
