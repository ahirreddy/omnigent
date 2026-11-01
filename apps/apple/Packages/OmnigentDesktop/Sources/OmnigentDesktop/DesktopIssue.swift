public import Foundation

/// A problem the desktop shell handled without crashing but that the app should log or show.
///
/// Every shell component reports through a `DesktopIssueReporter` instead of dropping errors.
nonisolated public enum DesktopIssue: Sendable {
  /// An `omnigent://` URL was not a supported link.
  case deepLinkRejected(String, DeepLinkError)
  /// The CLI did not answer its handshake with HTTP 204, so the link was left to the browser.
  case acknowledgmentDeclined(OmnigentDeepLink)
  /// The CLI handshake request failed, so the link was left to the browser.
  case acknowledgmentFailed(OmnigentDeepLink, DeepLinkAcknowledgmentError)
  /// The user declined to connect to a server they had never used.
  case consentDeclined(ServerOrigin)
  /// A window, known server or notification carried a URL that is not a valid http(s) server.
  case invalidServerURL(URL, ServerOriginError)
  /// A route was requested before any window could open others; it stays queued.
  case awaitingWindowOpener(pending: Int)
  /// A routing invariant did not hold, for example a window closed mid-request.
  case routingFailed(String)
  /// Posting or authorizing a notification failed.
  case notificationFailed(DesktopNotificationError)
  /// A notification tap carried a payload this version does not understand.
  case unrecognizedNotificationPayload(identifier: String)
}

/// Receives `DesktopIssue`s. The app binds this to its logger.
public typealias DesktopIssueReporter = @MainActor (DesktopIssue) -> Void

/// Writes issues to standard error. The default until the app installs its own reporter.
public enum StandardErrorIssueReporter {
  /// Writes one line describing `issue` to standard error.
  /// - Parameter issue: The issue.
  public static func report(_ issue: DesktopIssue) {
    FileHandle.standardError.write(Data("[OmnigentDesktop] \(issue)\n".utf8))
  }
}
