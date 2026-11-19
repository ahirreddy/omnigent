import OSLog
import OmnigentCoreFFI

/// This device's saved copy of sessions, which the core shows when the server cannot be reached.
extension ConnectionStore {
  private static let savedCopyLogger = Logger(subsystem: "ai.omnigent", category: "message-cache")

  /// Whether the sidebar and open sessions show what this device saved, because the server
  /// could not be reached. The app shows its sessions then rather than the sign-in screen.
  public var isOffline: Bool { offlineServerURL != nil }

  /// Whether the sidebar shows what this device saved while the app connects, before the
  /// server's own list replaces it.
  public var isShowingSavedList: Bool { savedListServerURL != nil }

  /// Whether to show the server's sessions: signed in, offline with a saved copy, or connecting
  /// with one.
  public var showsSessions: Bool { isSignedIn || isOffline || isShowingSavedList }

  /// The server whose sessions show: the connected one, or the one whose saved copy shows.
  public var shownServerURL: String? {
    connectedServer?.baseUrl ?? offlineServerURL ?? savedListServerURL
  }

  func offlineChanged(_ serverURL: String?) {
    if serverURL != offlineServerURL { offlineServerURL = serverURL }
    // The saved list belonged to the offline view; a sign-in screen starts without it.
    if serverURL == nil, !showsSessions { sessionList.clear() }
  }

  func savedListShown(_ serverURL: String?) {
    if serverURL != savedListServerURL { savedListServerURL = serverURL }
    // A connect that ended in a sign-in screen or a disconnect starts it without the list.
    if serverURL == nil, !showsSessions { sessionList.clear() }
  }

  /// Deletes this device's saved copy of `serverURL`'s sessions, for every account, as removing
  /// the server from the app should. A failure is recorded in ``issues``.
  /// - Parameter serverURL: The server, as typed or canonical.
  public func forgetSavedServer(_ serverURL: String) {
    core?.forgetSavedServer(serverUrl: serverURL)
  }

  /// Logs why the saved copy could not be read or written, when `event` says so; the store then
  /// shows it as any failure. The message names the file's role and the cause, never what the
  /// file holds.
  func logSavedCopyFailure(_ event: CoreEvent) {
    guard case .error(_, let error) = event, case .MessageCache = error else { return }
    Self.savedCopyLogger.error("\(error.message, privacy: .public)")
  }
}
