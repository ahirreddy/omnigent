public import Foundation

/// Every failure the embedded browser can report. Errors are surfaced to callers or shown in
/// the UI, never dropped.
nonisolated public enum BrowserError: Error, Hashable, Sendable {
  /// The platform cannot host the engine (Chromium on iOS).
  case engineUnsupported(BrowserEngineKind)
  /// The engine is supported but missing from this build or app bundle.
  case engineNotBundled(BrowserEngineKind, reason: String)
  /// The engine is bundled but failed to start. Sticky for the process lifetime.
  case engineFailedToStart(BrowserEngineKind, reason: String)
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
    }
  }
}
