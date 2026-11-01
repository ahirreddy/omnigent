public import Foundation

/// Every failure the web layer reports. Errors reach the caller or the UI; none are dropped.
nonisolated public enum WebLayerError: Error, Hashable, Sendable {
  /// The host app is missing from the bundle.
  case hostNotBundled(path: String)
  /// The host process could not be spawned.
  case launchFailed(String)
  /// The Mach channel could not be created or used.
  case channelFailed(String)
  /// The host connected but the handshake was invalid.
  case handshakeFailed(String)
  /// Client and host speak incompatible protocol major versions.
  case protocolMismatch(host: String, client: String)
  /// The host could not initialize Chromium.
  case hostInitializationFailed(String)
  /// The host did not reach a start-up milestone in time.
  case hostTimedOut(phase: String, seconds: Double)
  /// The host process exited while in use.
  case hostExited(status: Int32, reason: String)
  /// The host stopped answering pings and was terminated.
  case hostUnresponsive(seconds: Double)
  /// The host reported an error for a request or view.
  case hostError(code: UInt64, message: String)
  /// The session or view is not ready for this request yet.
  case notReady
  /// The view was closed.
  case viewClosed
  /// A main-frame navigation failed.
  case navigationFailed(url: URL?, code: Int, message: String)
  /// A navigation was superseded or stopped.
  case navigationCancelled(url: URL?)
  /// The page's renderer process exited.
  case rendererTerminated(String)
  /// Script evaluation threw.
  case scriptFailed(String)
  /// Script evaluation returned a value with no `WebScriptValue` equivalent.
  case unsupportedScriptResult(String)
  /// A DevTools Protocol call failed.
  case devToolsFailed(method: String, message: String)
  /// Capturing the page failed.
  case snapshotFailed(String)
  /// The page tried to download a file; downloads are not supported yet.
  case downloadBlocked(url: URL?)
  /// The page asked for UI the web layer does not project yet (dialogs, permission prompts,
  /// file choosers). The request was denied.
  case featureBlocked(feature: String, detail: String)
  /// The chosen rendering path cannot work on this system.
  case renderingUnavailable(String)
  /// A caller passed an invalid argument.
  case invalidArgument(String)
  /// The view's navigation rules stopped a navigation (protocol 1.1).
  case navigationBlocked(url: URL?, reason: String)
  /// The popup policy stopped a window.open or target=_blank (protocol 1.1).
  case popupBlocked(url: URL?, reason: String)
  /// The prompt was already answered or withdrawn (protocol 1.1).
  case promptFinished(String)

  /// Whether restarting the host can fix the error.
  public var isRecoverableByRestart: Bool {
    switch self {
    case .hostExited, .hostUnresponsive, .hostTimedOut, .channelFailed, .hostInitializationFailed:
      true
    default:
      false
    }
  }

  /// Whether the error only reflects a superseded or stopped navigation.
  public var isCancellation: Bool {
    if case .navigationCancelled = self { return true }
    return false
  }
}

extension WebLayerError: LocalizedError {
  /// Human-readable description for alerts and inline banners.
  nonisolated public var errorDescription: String? {
    switch self {
    case .hostNotBundled(let path):
      "The Chromium web host is not bundled with this app (\(path))."
    case .launchFailed(let message):
      "The Chromium web host could not be launched: \(message)"
    case .channelFailed(let message):
      "The connection to the Chromium web host failed: \(message)"
    case .handshakeFailed(let message):
      "The Chromium web host handshake failed: \(message)"
    case .protocolMismatch(let host, let client):
      "The Chromium web host speaks protocol \(host), but this app needs \(client)."
    case .hostInitializationFailed(let message):
      "Chromium failed to start: \(message)"
    case .hostTimedOut(let phase, let seconds):
      "The Chromium web host did not finish \(phase) within \(Int(seconds)) seconds."
    case .hostExited(let status, let reason):
      "The Chromium web host stopped (\(reason), status \(status))."
    case .hostUnresponsive(let seconds):
      "The Chromium web host stopped responding for \(Int(seconds)) seconds and was restarted."
    case .hostError(let code, let message):
      "The Chromium web host reported error \(code): \(message)"
    case .notReady:
      "The page is still starting."
    case .viewClosed:
      "The page was closed."
    case .navigationFailed(let url, let code, let message):
      "Could not load \(url?.absoluteString ?? "the page") (\(code)): \(message)"
    case .navigationCancelled(let url):
      "Loading \(url?.absoluteString ?? "the page") was cancelled."
    case .rendererTerminated(let message):
      "The page's renderer process stopped: \(message)"
    case .scriptFailed(let message):
      "Script failed: \(message)"
    case .unsupportedScriptResult(let type):
      "Script returned an unsupported value of type \(type)."
    case .devToolsFailed(let method, let message):
      "DevTools call \(method) failed: \(message)"
    case .snapshotFailed(let message):
      "Could not capture the page: \(message)"
    case .downloadBlocked(let url):
      "Downloads are not supported yet (\(url?.absoluteString ?? "unknown URL"))."
    case .featureBlocked(let feature, let detail):
      "\(feature) is not supported yet and was blocked: \(detail)"
    case .renderingUnavailable(let message):
      "The page cannot be displayed: \(message)"
    case .invalidArgument(let message):
      "Invalid argument: \(message)"
    case .navigationBlocked(let url, let reason):
      "Navigation to \(url?.absoluteString ?? "the page") was blocked: \(reason)"
    case .popupBlocked(let url, let reason):
      "A popup for \(url?.absoluteString ?? "a page") was blocked: \(reason)"
    case .promptFinished(let message):
      "The request was already handled: \(message)"
    }
  }
}
