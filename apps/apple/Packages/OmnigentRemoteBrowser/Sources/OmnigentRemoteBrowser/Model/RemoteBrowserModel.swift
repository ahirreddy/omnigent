public import Foundation
public import OmnigentCoreFFI

/// The core's modifier bits for remote input records (`MouseInput.modifiers`,
/// `KeyInput.modifiers`).
nonisolated public struct RemoteModifiers: OptionSet, Hashable, Sendable {
  /// The bits.
  public let rawValue: UInt32

  /// Creates modifiers.
  /// - Parameter rawValue: The bits.
  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  /// Shift.
  public static let shift = Self(rawValue: 1 << 0)
  /// Control.
  public static let control = Self(rawValue: 1 << 1)
  /// Option / Alt.
  public static let alt = Self(rawValue: 1 << 2)
  /// Command / Meta.
  public static let meta = Self(rawValue: 1 << 3)
  /// Caps Lock.
  public static let capsLock = Self(rawValue: 1 << 4)
  /// Num Lock.
  public static let numLock = Self(rawValue: 1 << 5)
  /// The left button is down.
  public static let leftButton = Self(rawValue: 1 << 6)
  /// The middle button is down.
  public static let middleButton = Self(rawValue: 1 << 7)
  /// The right button is down.
  public static let rightButton = Self(rawValue: 1 << 8)
}

extension ImeRange {
  /// The range of an `NSRange`, or `nil` for `NSNotFound`.
  /// - Parameter range: The range.
  nonisolated public init?(_ range: NSRange) {
    guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
    self.init(start: UInt32(clamping: range.location), end: UInt32(clamping: NSMaxRange(range)))
  }
}

extension RemoteBrowserSnapshot {
  /// What a tab shows before the core reports anything: its saved URL and profile.
  /// - Parameters:
  ///   - url: The saved URL.
  ///   - profile: The saved profile.
  /// - Returns: An idle snapshot.
  nonisolated public static func initial(url: String, profile: String) -> Self {
    Self(
      connection: .idle, mode: nil, profile: profile, hostVersion: nil,
      nav: RemoteBrowserNav(
        url: url, title: "", loading: false, progress: 1, canGoBack: false,
        canGoForward: false, faviconUrl: nil),
      control: nil, wantsControl: false, cursor: RemoteBrowserCursor(keyword: "default", custom: nil),
      textInput: RemoteBrowserTextInput(mode: .none, caret: nil), viewport: nil, settings: nil,
      stats: nil, dialogs: [])
  }

  /// Whether the remote tab is gone.
  nonisolated public var isEnded: Bool {
    if case .closed = connection { return true }
    return false
  }
}

/// A server's remote browsers: profiles, tab creation and the attach factory. The app uses the
/// core (``CoreRemoteBrowserConnector``); previews and tests use ``FixtureRemoteBrowser``.
nonisolated public protocol RemoteBrowserConnecting: AnyObject, Sendable {
  /// The agent machine's browser profiles for a session.
  /// - Parameter sessionID: The session.
  /// - Returns: The profiles.
  /// - Throws: `CoreError.RemoteBrowser`.
  func profiles(sessionID: String) async throws -> [RemoteBrowserProfile]
  /// Creates a remote tab.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - url: The first page, or the host's default.
  ///   - profile: The profile, or the default.
  /// - Returns: The tab.
  /// - Throws: `CoreError.RemoteBrowser`.
  func createTab(sessionID: String, url: String?, profile: String?) async throws
    -> RemoteBrowserTab
  /// Closes a remote tab; one that is already gone counts as closed.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The tab.
  /// - Throws: `CoreError.RemoteBrowser`.
  func closeTab(sessionID: String, tabID: String) async throws
  /// Attaches to a tab; the driver is idle until `start()`.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The tab.
  ///   - mode: View or control.
  ///   - hostID: The session's host, when it has one.
  ///   - listener: Receives the stream.
  /// - Returns: The driver.
  func attach(
    sessionID: String, tabID: String, mode: RemoteBrowserMode, hostID: String?,
    listener: any RemoteBrowserListener
  ) -> any RemoteBrowserDriverProtocol
}

/// The core's remote browser REST calls and attach factory.
public final class CoreRemoteBrowserConnector: RemoteBrowserConnecting {
  private let core: ClientCore

  /// Wraps a connection's core.
  /// - Parameter core: The core.
  public nonisolated init(core: ClientCore) {
    self.core = core
  }

  /// The profiles.
  public nonisolated func profiles(sessionID: String) async throws -> [RemoteBrowserProfile] {
    try await core.listRemoteBrowserProfiles(sessionId: sessionID)
  }

  /// Creates a tab.
  public nonisolated func createTab(sessionID: String, url: String?, profile: String?)
    async throws -> RemoteBrowserTab
  {
    try await core.createRemoteBrowser(sessionId: sessionID, url: url, profile: profile)
  }

  /// Closes a tab.
  public nonisolated func closeTab(sessionID: String, tabID: String) async throws {
    // `false` means the host no longer had the tab, which is the goal.
    _ = try await core.deleteRemoteBrowser(sessionId: sessionID, tabId: tabID)
  }

  /// Attaches to a tab.
  public nonisolated func attach(
    sessionID: String, tabID: String, mode: RemoteBrowserMode, hostID: String?,
    listener: any RemoteBrowserListener
  ) -> any RemoteBrowserDriverProtocol {
    core.remoteBrowserAttach(
      sessionId: sessionID, tabId: tabID, mode: mode, hostId: hostID, listener: listener)
  }
}
