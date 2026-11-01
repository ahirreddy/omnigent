public import Foundation

/// Where credentials apply.
nonisolated public struct BrowserProtectionSpace: Sendable, Hashable {
  /// Host.
  public let host: String
  /// Port.
  public let port: Int
  /// Realm, possibly empty.
  public let realm: String
  /// Scheme, for example "basic".
  public let scheme: String
  /// Whether it is a proxy.
  public let isProxy: Bool
  /// Whether the server uses TLS.
  public let isSecure: Bool

  /// Creates a protection space.
  public init(host: String, port: Int, realm: String, scheme: String, isProxy: Bool, isSecure: Bool)
  {
    self.host = host
    self.port = port
    self.realm = realm
    self.scheme = scheme
    self.isProxy = isProxy
    self.isSecure = isSecure
  }
}

/// A user name and password.
nonisolated public struct BrowserCredential: Sendable, Hashable {
  /// The user name.
  public let username: String
  /// The password. Never logged or persisted unless the user opts into the Keychain.
  public let password: String

  /// Creates a credential.
  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

/// HTTP or proxy authentication.
public final class BrowserAuthPrompt: BrowserPromptBase {
  /// Where the credentials apply.
  public let space: BrowserProtectionSpace
  private let answer: (BrowserCredential?) -> Void

  /// Creates a prompt; `answer` gets credentials, or nil to cancel.
  package init(space: BrowserProtectionSpace, answer: @escaping (BrowserCredential?) -> Void) {
    self.space = space
    self.answer = answer
  }

  /// Answers with credentials.
  public func respond(_ credential: BrowserCredential) {
    if finish() { answer(credential) }
  }

  /// Cancels.
  public func cancel() {
    if finish() { answer(nil) }
  }
}

/// A certificate error. Proceed only when `isOverridable` and the app's policy allows it.
public final class BrowserCertificatePrompt: BrowserPromptBase {
  /// The URL that failed.
  public let url: URL?
  /// What is wrong.
  public let message: String
  /// Engine error code (Chromium net error, or the WebKit trust result).
  public let errorCode: Int
  /// Certificate subject, possibly empty.
  public let subject: String
  /// Certificate issuer, possibly empty.
  public let issuer: String
  /// Whether proceeding is possible at all.
  public let isOverridable: Bool
  private let answer: (_ proceed: Bool) -> Void

  /// Creates a prompt; `answer` gets whether to proceed.
  package init(
    url: URL?, message: String, errorCode: Int, subject: String, issuer: String,
    isOverridable: Bool, answer: @escaping (Bool) -> Void
  ) {
    self.url = url
    self.message = message
    self.errorCode = errorCode
    self.subject = subject
    self.issuer = issuer
    self.isOverridable = isOverridable
    self.answer = answer
  }

  /// Proceeds. Throws when the error is not overridable; the load then stays blocked.
  public func proceed() throws(BrowserError) {
    guard isOverridable else {
      cancel()
      throw .notAllowed("This certificate error cannot be overridden.")
    }
    if finish() { answer(true) }
  }

  /// Goes back to safety.
  public func cancel() {
    if finish() { answer(false) }
  }
}

/// `<input type=color>`.
public final class BrowserColorPrompt: BrowserPromptBase {
  /// The current value, "#rrggbb".
  public let initialColor: String
  private let answer: (String?) -> Void

  /// Creates a prompt; `answer` gets "#rrggbb", or nil to leave the input unchanged.
  package init(initialColor: String, answer: @escaping (String?) -> Void) {
    self.initialColor = initialColor
    self.answer = answer
  }

  /// Sets the color.
  public func choose(_ hex: String) {
    if finish() { answer(hex) }
  }

  /// Leaves the input unchanged.
  public func cancel() {
    if finish() { answer(nil) }
  }
}
