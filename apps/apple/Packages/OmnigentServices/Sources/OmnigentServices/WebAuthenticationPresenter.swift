public import AuthenticationServices
public import Foundation
import Synchronization

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Supplies the window that the sign-in sheet attaches to. macOS uses an `NSWindow`; iOS uses a
/// `UIWindow` (`ASPresentationAnchor` is a typealias for each).
@MainActor
public protocol WebAuthenticationAnchorProviding: AnyObject {
  /// The window to present from, or nil when no window is available.
  func presentationAnchor() -> ASPresentationAnchor?
}

/// The callback forms `ASWebAuthenticationSession` can receive. Loopback redirects are not one
/// of them: ``LoopbackRedirectListener`` receives those, and the sheet is dismissed by
/// cancelling its task.
public enum WebAuthenticationCallback: Sendable, Equatable {
  /// A custom URL scheme, such as `ai.omnigent.ios`.
  case customScheme(String)
  /// An https callback on a host the app has associated with its domain.
  case https(host: String, path: String)
}

/// Why an interactive sign-in did not produce a callback.
public enum WebAuthenticationError: Error, Sendable, Equatable {
  /// The user dismissed the sheet.
  case cancelled
  /// The session could not start, or it ended with an error.
  case failed(message: String)
}

private typealias OutcomeContinuation = CheckedContinuation<
  Result<URL, WebAuthenticationError>, Never
>

/// The part of `ASWebAuthenticationSession` a sign-in drives.
@MainActor
protocol WebAuthenticationSessionRunning: AnyObject {
  /// Supplies the window. The session holds it weakly.
  var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? {
    get set
  }
  /// Whether to skip the browser's shared cookies.
  var prefersEphemeralWebBrowserSession: Bool { get set }
  /// Shows the sign-in sheet.
  /// - Returns: Whether the session started.
  func start() -> Bool
  /// Dismisses the sheet.
  func cancel()
}

extension ASWebAuthenticationSession: WebAuthenticationSessionRunning {}

/// Runs an `ASWebAuthenticationSession` for OIDC sign-in and returns its callback URL.
@MainActor
public final class WebAuthenticationPresenter {
  /// Makes a session from its URL, callback and completion.
  typealias SessionFactory =
    @MainActor (
      URL, WebAuthenticationCallback, @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> any WebAuthenticationSessionRunning

  private let makeSession: SessionFactory
  private var activeSession: (any WebAuthenticationSessionRunning)?
  private var presentationContext: SignInPresentationContext?

  /// Creates a presenter.
  public convenience init() {
    self.init(makeSession: Self.makeSystemSession)
  }

  /// Creates a presenter over `makeSession`, so a sign-in can run without a sheet.
  init(makeSession: @escaping SessionFactory) {
    self.makeSession = makeSession
  }

  /// A system session, not started.
  /// - Parameters:
  ///   - url: The authorization URL.
  ///   - callback: The redirect the session intercepts.
  ///   - completion: Receives the callback URL or the error.
  /// - Returns: The session.
  static func makeSystemSession(
    url: URL, callback: WebAuthenticationCallback,
    completion: @escaping @Sendable (URL?, (any Error)?) -> Void
  ) -> any WebAuthenticationSessionRunning {
    ASWebAuthenticationSession(
      url: url, callback: callback.sessionCallback, completionHandler: completion)
  }

  /// Presents the sign-in page and waits for the callback.
  /// - Parameters:
  ///   - url: The authorization URL.
  ///   - callback: The redirect the session intercepts.
  ///   - prefersEphemeralSession: Whether to skip the browser's shared cookies.
  ///   - anchorProvider: Supplies the window to present from.
  /// - Returns: The full callback URL, including its query.
  /// - Throws: ``WebAuthenticationError/cancelled`` when the user dismisses the sheet or the
  ///   calling task is cancelled (which dismisses it), or
  ///   ``WebAuthenticationError/failed(message:)`` for every other outcome.
  public func authenticate(
    url: URL,
    callback: WebAuthenticationCallback,
    prefersEphemeralSession: Bool = false,
    anchorProvider: any WebAuthenticationAnchorProviding
  ) async throws(WebAuthenticationError) -> URL {
    guard activeSession == nil else {
      throw .failed(message: "A sign-in is already in progress.")
    }
    guard let anchor = anchorProvider.presentationAnchor() else {
      throw .failed(message: "No window is available to present the sign-in sheet.")
    }
    let context = SignInPresentationContext(anchor: anchor)
    presentationContext = context
    defer {
      activeSession = nil
      presentationContext = nil
    }

    let waiter = OutcomeWaiter()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: OutcomeContinuation) in
        guard waiter.wait(continuation) else { return }
        let session = makeSession(url, callback) { @Sendable callbackURL, error in
          // The completion's queue is undocumented, so it must not assume the main actor.
          waiter.resume(returning: Self.outcome(callbackURL: callbackURL, error: error))
        }
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
        activeSession = session
        guard session.start() else {
          waiter.resume(
            returning: .failure(.failed(message: "The sign-in session could not start.")))
          return
        }
      }
    } onCancel: {
      waiter.resume(returning: .failure(.cancelled))
    }
    if Task.isCancelled { activeSession?.cancel() }
    switch outcome {
    case .success(let callbackURL):
      return callbackURL
    case .failure(let error):
      throw error
    }
  }

  /// Maps the session's completion values onto a typed outcome.
  nonisolated static func outcome(
    callbackURL: URL?, error: (any Error)?
  ) -> Result<URL, WebAuthenticationError> {
    if let error {
      if let sessionError = error as? ASWebAuthenticationSessionError,
        sessionError.code == .canceledLogin
      {
        return .failure(.cancelled)
      }
      return .failure(.failed(message: error.localizedDescription))
    }
    guard let callbackURL else {
      return .failure(.failed(message: "The sign-in session ended without a callback URL."))
    }
    return .success(callbackURL)
  }
}

/// Gives a session the window captured when its sign-in started.
@MainActor
private final class SignInPresentationContext: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  private let anchor: ASPresentationAnchor

  init(anchor: ASPresentationAnchor) {
    self.anchor = anchor
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    anchor
  }
}

/// Resumes a sign-in once. Apple doesn't say whether a session that fails to start also calls its
/// completion, and a second resume would crash the app. An outcome that arrives before the wait
/// (a task cancelled before the session was made) is kept for it.
private final class OutcomeWaiter: Sendable {
  private struct State {
    var continuation: OutcomeContinuation?
    var early: Result<URL, WebAuthenticationError>?
    var resumed = false
  }

  private let state = Mutex(State())

  /// Parks `continuation` until the outcome; resumes it at once with one that already arrived.
  /// - Returns: Whether the sign-in should go on.
  func wait(_ continuation: OutcomeContinuation) -> Bool {
    let early = state.withLock { state -> Result<URL, WebAuthenticationError>? in
      if let early = state.early {
        state.resumed = true
        return early
      }
      state.continuation = continuation
      return nil
    }
    guard let early else { return true }
    continuation.resume(returning: early)
    return false
  }

  func resume(returning outcome: Result<URL, WebAuthenticationError>) {
    let waiting = state.withLock { state -> OutcomeContinuation? in
      guard !state.resumed else { return nil }
      guard let continuation = state.continuation else {
        if state.early == nil { state.early = outcome }
        return nil
      }
      state.resumed = true
      state.continuation = nil
      return continuation
    }
    waiting?.resume(returning: outcome)
  }
}

extension WebAuthenticationCallback {
  var sessionCallback: ASWebAuthenticationSession.Callback {
    switch self {
    case .customScheme(let scheme):
      .customScheme(scheme)
    case .https(let host, let path):
      .https(host: host, path: path)
    }
  }
}

/// Presents from the app's key window.
@MainActor
public final class KeyWindowAnchorProvider: WebAuthenticationAnchorProviding {
  /// Creates a provider.
  public init() {}

  /// The key window, or the main window on macOS when no window is key.
  public func presentationAnchor() -> ASPresentationAnchor? {
    #if os(macOS)
      NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    #else
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }
    #endif
  }
}
