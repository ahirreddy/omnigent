public import Foundation

/// Every failure the embedded browser can report. Errors are surfaced to callers or shown in
/// the UI, never dropped.
nonisolated public enum BrowserError: Error, Hashable, Sendable {
  /// The platform cannot host the engine (Chromium on iOS).
  case engineUnsupported(BrowserEngineKind)
  /// The engine is supported but missing from this build or app bundle.
  case engineNotBundled(BrowserEngineKind, reason: String)
  /// The engine is bundled but failed to start. The provider remembers it until relaunch.
  case engineFailedToStart(BrowserEngineKind, reason: String)
  /// The engine's process stopped or hung while in use. Reloading the tab restarts it.
  case engineStopped(BrowserEngineKind, reason: String)
  /// The engine reported an error that has no more specific case.
  case engineError(BrowserEngineKind, message: String)
  /// A string could not be turned into a loadable URL.
  case invalidURL(String)
  /// A main-frame navigation failed.
  case navigationFailed(url: URL?, code: Int, message: String)
  /// A navigation was superseded or stopped. Reported, but not presented as a failure.
  case navigationCancelled(url: URL?)
  /// The web content (renderer) process exited.
  case contentProcessTerminated(reason: String)
  /// Script evaluation threw or could not run.
  case scriptFailed(message: String)
  /// Script evaluation produced a value with no `BrowserScriptValue` equivalent.
  case unsupportedScriptResult(String)
  /// The page tried to start a download, which this build does not support yet.
  case downloadsUnsupported(url: URL?)
  /// The engine does not implement the feature.
  case featureUnsupported(feature: String, engine: BrowserEngineKind)
  /// A Chrome DevTools Protocol call failed.
  case devToolsFailed(method: String, message: String)
  /// The tab has not finished creating its engine view yet.
  case tabNotReady
  /// The tab was closed.
  case tabClosed
  /// Capturing a page snapshot failed.
  case snapshotFailed(String)
  /// Find-in-page failed.
  case findFailed(String)
  /// A URL policy or navigation rule stopped a navigation.
  case navigationBlocked(url: URL?, reason: String)
  /// The popup policy stopped a window the page opened.
  case popupBlocked(url: URL?, reason: String)
  /// The request is not allowed (an override the policy forbids, for example).
  case notAllowed(String)
  /// A download failed or could not be controlled.
  case downloadFailed(String)
  /// Storing or reading a credential failed (Keychain status in the message).
  case credentialStoreFailed(String)
  /// Agent input or an agent action failed.
  case agentActionFailed(String)

  /// Whether the error only reflects a superseded or stopped navigation.
  public var isCancellation: Bool {
    if case .navigationCancelled = self { return true }
    return false
  }
}

extension BrowserError: LocalizedError {
  /// Human-readable description for alerts and inline banners.
  nonisolated public var errorDescription: String? {
    switch self {
    case .engineUnsupported(let kind):
      "\(kind.displayName) is not available on this platform."
    case .engineNotBundled(let kind, let reason):
      "\(kind.displayName) is not included in this build. \(reason)"
    case .engineFailedToStart(let kind, let reason):
      "\(kind.displayName) failed to start. \(reason)"
    case .engineStopped(let kind, let reason):
      "\(kind.displayName) stopped. \(reason) Reload to restart it."
    case .engineError(let kind, let message):
      "\(kind.displayName) reported an error: \(message)"
    case .invalidURL(let text):
      "\"\(text)\" is not a valid URL."
    case .navigationFailed(let url, let code, let message):
      "Could not load \(url?.absoluteString ?? "the page") (\(code)): \(message)"
    case .navigationCancelled(let url):
      "Loading \(url?.absoluteString ?? "the page") was cancelled."
    case .contentProcessTerminated(let reason):
      "The page's web content process stopped: \(reason)"
    case .scriptFailed(let message):
      "Script failed: \(message)"
    case .unsupportedScriptResult(let type):
      "Script returned an unsupported value of type \(type)."
    case .downloadsUnsupported(let url):
      "Downloads are not supported yet (\(url?.absoluteString ?? "unknown URL"))."
    case .featureUnsupported(let feature, let engine):
      "\(engine.displayName) does not support \(feature)."
    case .devToolsFailed(let method, let message):
      "DevTools call \(method) failed: \(message)"
    case .tabNotReady:
      "The browser tab is still starting."
    case .tabClosed:
      "The browser tab was closed."
    case .snapshotFailed(let message):
      "Could not capture the page: \(message)"
    case .findFailed(let message):
      "Find in page failed: \(message)"
    case .navigationBlocked(let url, let reason):
      "Navigation to \(url?.absoluteString ?? "the page") was blocked: \(reason)"
    case .popupBlocked(let url, let reason):
      "A popup for \(url?.absoluteString ?? "a page") was blocked: \(reason)"
    case .notAllowed(let message):
      "Not allowed: \(message)"
    case .downloadFailed(let message):
      "Download failed: \(message)"
    case .credentialStoreFailed(let message):
      "Saving or reading the password failed: \(message)"
    case .agentActionFailed(let message):
      "The browser action failed: \(message)"
    }
  }
}
