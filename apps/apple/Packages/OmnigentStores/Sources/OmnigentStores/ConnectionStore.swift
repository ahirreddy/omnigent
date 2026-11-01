import Foundation
public import Observation
public import OmnigentCoreFFI
import OmnigentServices

/// Connection to one Omnigent server, starting with discovery of its manifest.
@Observable
public final class ConnectionStore {
  /// Where discovery stands.
  public enum State: Equatable {
    /// No discovery has run yet, or the store was reset.
    case idle
    /// Discovery of `serverURL` is in flight.
    case loading(serverURL: String)
    /// The server answered with its manifest.
    case connected(ServerDiscovery)
    /// Discovery of `serverURL` failed; `message` is suitable for display.
    case failed(serverURL: String, message: String)
  }

  /// The current discovery state.
  public private(set) var state: State = .idle

  private let core: ClientCore
  private var attempt = 0

  /// Creates a store over an existing core.
  /// - Parameter core: The Rust client core.
  public init(core: ClientCore) {
    self.core = core
  }

  /// Creates a store whose core sends requests through `transport`.
  /// - Parameter transport: The host HTTP transport.
  public convenience init(transport: any HttpTransport) {
    self.init(core: ClientCore(transport: transport))
  }

  /// Creates a store backed by `URLSessionHttpTransport`.
  public convenience init() {
    self.init(transport: URLSessionHttpTransport())
  }

  /// Whether discovery is in flight.
  public var isLoading: Bool {
    if case .loading = state { return true }
    return false
  }

  /// The discovered server, when connected.
  public var discovery: ServerDiscovery? {
    if case .connected(let discovery) = state { return discovery }
    return nil
  }

  /// The failure message, when discovery failed.
  public var errorMessage: String? {
    if case .failed(_, let message) = state { return message }
    return nil
  }

  /// Runs discovery against `serverURL` and publishes the outcome in ``state``.
  ///
  /// A newer call supersedes an in-flight one: the older outcome is dropped because the user has
  /// already asked for a different server.
  /// - Parameter serverURL: The server URL as typed by the user.
  public func discover(serverURL: String) async {
    let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    attempt += 1
    let current = attempt
    state = .loading(serverURL: trimmed)
    let next: State
    do {
      next = .connected(try await core.discoverServer(serverUrl: trimmed))
    } catch {
      next = .failed(serverURL: trimmed, message: Self.describe(error))
    }
    guard current == attempt else { return }
    state = next
  }

  /// Returns to ``State/idle`` and drops any in-flight outcome.
  public func reset() {
    attempt += 1
    state = .idle
  }

  /// A user-facing description of a discovery failure.
  /// - Parameter error: The error thrown by the core.
  /// - Returns: Text suitable for display.
  public static func describe(_ error: any Error) -> String {
    guard let coreError = error as? CoreError else {
      return String(describing: error)
    }
    switch coreError {
    case .InvalidUrl(let message):
      return "Invalid server URL: \(message)"
    case .Transport(let message):
      return "Could not reach the server: \(message)"
    case .HttpStatus(let status, let body):
      let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
      return snippet.isEmpty
        ? "Server responded with HTTP \(status)"
        : "Server responded with HTTP \(status): \(snippet)"
    case .Decode(let message):
      return "Unexpected server response: \(message)"
    }
  }
}

extension AuthMode {
  /// A short user-facing name for the sign-in mode.
  public var displayName: String {
    switch self {
    case .oidc: "OpenID Connect"
    case .accounts: "Accounts"
    case .header: "Header"
    case .custom: "Custom"
    case .none: "None"
    case .unknown(let value): "Unknown (\(value))"
    }
  }
}
