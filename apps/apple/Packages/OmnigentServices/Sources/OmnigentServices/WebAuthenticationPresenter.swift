public import AuthenticationServices
public import Foundation

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
/// of them: use ``LoopbackRedirectListener`` with the system browser for those.
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

/// Runs an `ASWebAuthenticationSession` for OIDC sign-in and returns its callback URL.
@MainActor
public final class WebAuthenticationPresenter: NSObject,
  ASWebAuthenticationPresentationContextProviding
{
  private var activeSession: ASWebAuthenticationSession?
  private var presentingAnchor: ASPresentationAnchor?

  /// Creates a presenter.
  public override init() {
    super.init()
  }

  /// Presents the sign-in page and waits for the callback.
  /// - Parameters:
  ///   - url: The authorization URL.
  ///   - callback: The redirect the session intercepts.
  ///   - prefersEphemeralSession: Whether to skip the browser's shared cookies.
  ///   - anchorProvider: Supplies the window to present from.
  /// - Returns: The full callback URL, including its query.
  /// - Throws: ``WebAuthenticationError/cancelled`` when the user dismisses the sheet, or
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
    presentingAnchor = anchor
    defer {
      activeSession = nil
      presentingAnchor = nil
    }

    let outcome = await withCheckedContinuation { (continuation: OutcomeContinuation) in
      let session = ASWebAuthenticationSession(
        url: url, callback: callback.sessionCallback
      ) { callbackURL, error in
        continuation.resume(returning: Self.outcome(callbackURL: callbackURL, error: error))
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
      activeSession = session
      guard session.start() else {
        continuation.resume(
          returning: .failure(.failed(message: "The sign-in session could not start.")))
        return
      }
    }
    switch outcome {
    case .success(let callbackURL):
      return callbackURL
    case .failure(let error):
      throw error
    }
  }

  /// The anchor captured when the sign-in started.
  /// - Parameter session: The session asking for its window.
  /// - Returns: The window the sign-in sheet attaches to.
  public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    guard let presentingAnchor else {
      preconditionFailure("The sign-in session asked for an anchor outside authenticate(url:).")
    }
    return presentingAnchor
  }

  /// Maps the session's completion values onto a typed outcome.
  static func outcome(
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

extension WebAuthenticationCallback {
  fileprivate var sessionCallback: ASWebAuthenticationSession.Callback {
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
