import Foundation

/// A connection or sign-in failure, as the UI shows it.
///
/// Mirrors the auth-relevant shape of `omnigent-ffi` `CoreError`: ``category`` is the variant,
/// ``failure`` is the `failure` field of `CoreError.Auth` and `CoreError.Oidc`, and ``message`` is
/// the core's user-facing text (its `Display`), which never carries a credential.
public nonisolated struct SignInError: Error, Hashable, Sendable {
  /// Which `CoreError` variant this came from.
  public enum Category: Hashable, Sendable {
    /// `CoreError.InvalidUrl`: the URL was rejected before any request.
    case invalidUrl
    /// `CoreError.Transport`: the host transport failed.
    case transport
    /// `CoreError.HttpStatus`: an unexpected status. The body is deliberately not kept.
    case httpStatus(status: UInt16)
    /// `CoreError.Decode`: a response could not be decoded.
    case decode
    /// `CoreError.Auth`: hosted sign-in or identity confirmation failed.
    case auth
    /// `CoreError.Oidc`: native OIDC sign-in, refresh or sign-out failed.
    case oidc
    /// `CoreError.SecureStore`: the Keychain failed.
    case secureStore
    /// Any other variant.
    case other
  }

  /// Which variant this came from.
  public var category: Category
  /// What it means for the user, for `Auth` and `Oidc` errors.
  public var failure: SignInFailure?
  /// The core's message, for display.
  public var message: String
  /// The server's own explanation (its `error` text), verbatim, when the core kept one outside
  /// ``SignInFailure/refused(reason:)``, for example the accounts login's
  /// "invalid username or password".
  public var serverReason: String?

  /// Creates an error.
  /// - Parameters:
  ///   - category: Which `CoreError` variant this came from.
  ///   - failure: The `AuthFailure`, for `Auth` and `Oidc` errors.
  ///   - message: The core's message.
  ///   - serverReason: The server's own explanation, verbatim.
  public init(
    category: Category, failure: SignInFailure? = nil, message: String, serverReason: String? = nil
  ) {
    self.category = category
    self.failure = failure
    self.message = message
    self.serverReason = serverReason
  }

  /// The server's refusal reason to show verbatim: the refused reason, else ``serverReason``.
  /// Blank reasons count as none.
  public var refusalReason: String? {
    let reason: String?
    if case .refused(let refused) = failure {
      reason = refused ?? serverReason
    } else {
      reason = serverReason
    }
    guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return reason
  }

  /// Whether connecting again may fix it (the network or the server's status), so the UI offers
  /// Retry.
  public var isRetryable: Bool {
    switch category {
    case .transport, .httpStatus: return true
    case .invalidUrl, .decode, .auth, .oidc, .secureStore, .other: return failure == .transport
    }
  }

  /// A short title for the failure.
  public var title: String {
    switch failure {
    case .refused: return "Sign-in refused"
    case .expired: return "Sign-in expired"
    case .endedByServer: return "Session ended"
    case .signInRequired: return "Sign-in required"
    case .transport: return "Can\u{2019}t reach the server"
    case .failed, nil: break
    }
    switch category {
    case .invalidUrl: return "Check the server URL"
    case .transport: return "Can\u{2019}t reach the server"
    case .httpStatus(let status): return "The server returned HTTP \(status)"
    case .decode: return "Unexpected server response"
    case .secureStore: return "Keychain unavailable"
    case .auth, .oidc, .other: return "Couldn\u{2019}t connect"
    }
  }

  /// The body text: ``message``, or `nil` when it only repeats the refusal reason (an OIDC
  /// refusal's message is the reason itself).
  public var detail: String? {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == refusalReason?.trimmingCharacters(in: .whitespacesAndNewlines)
    {
      return nil
    }
    return message
  }
}
