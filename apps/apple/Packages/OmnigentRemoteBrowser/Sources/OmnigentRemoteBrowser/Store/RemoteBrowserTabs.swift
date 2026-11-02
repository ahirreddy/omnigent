public import Foundation
public import Observation
public import OmnigentCoreFFI

/// What a remote browser tab saves so it can show its last page before it reattaches, and
/// reopen it once it ended.
nonisolated public struct RemoteBrowserTabRecord: Codable, Hashable, Sendable {
  /// The last URL.
  public var url: String
  /// The profile.
  public var profile: String

  /// Creates a record.
  /// - Parameters:
  ///   - url: Last URL.
  ///   - profile: Profile.
  public init(url: String, profile: String) {
    self.url = url
    self.profile = profile
  }

  /// Encodes the record for a tab's opaque restore state.
  /// - Returns: JSON.
  /// - Throws: An encoding error.
  public func encoded() throws -> Data {
    try JSONEncoder().encode(self)
  }

  /// Decodes a tab's restore state.
  /// - Parameter data: JSON from ``encoded()``.
  /// - Throws: A decoding error.
  public init(decoding data: Data) throws {
    self = try JSONDecoder().decode(Self.self, from: data)
  }
}

/// A connection's remote browser tabs: one live ``RemoteBrowserStore`` per open tab, kept while
/// the tab exists so switching tabs keeps the stream, plus profiles and tab creation.
@Observable
public final class RemoteBrowserTabs {
  /// The server's remote browsers.
  public let connector: any RemoteBrowserConnecting
  /// Profiles per session, once read.
  public private(set) var profiles: [String: [RemoteBrowserProfile]] = [:]
  /// The last failure of a create or profile read.
  public private(set) var lastError: String?
  // Observed, so tab titles update once a restored tab's store exists.
  private var stores: [String: RemoteBrowserStore] = [:]

  /// Creates the registry.
  /// - Parameter connector: The server's remote browsers.
  public init(connector: any RemoteBrowserConnecting) {
    self.connector = connector
  }

  /// The live store for a tab, created on first use; attach it with ``attach(_:mode:hostID:)``.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The host's tab id.
  ///   - record: The tab's saved state, shown until the host reports its own.
  /// - Returns: The store.
  public func store(sessionID: String, tabID: String, record: RemoteBrowserTabRecord?)
    -> RemoteBrowserStore
  {
    let key = Self.key(sessionID, tabID)
    if let store = stores[key] { return store }
    let store = RemoteBrowserStore(
      sessionID: sessionID, tabID: tabID, lastURL: record?.url ?? "",
      profile: record?.profile ?? "default")
    stores[key] = store
    return store
  }

  /// Attaches a store through this registry's connector (once).
  /// - Parameters:
  ///   - store: The store.
  ///   - mode: View or control, from the session's permission level.
  ///   - hostID: The session's host.
  public func attach(_ store: RemoteBrowserStore, mode: RemoteBrowserMode, hostID: String?) {
    store.attach(using: connector, mode: mode, hostID: hostID)
  }

  /// The live store for a tab, if it was attached.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The tab.
  /// - Returns: The store.
  public func existingStore(sessionID: String, tabID: String) -> RemoteBrowserStore? {
    stores[Self.key(sessionID, tabID)]
  }

  /// Reads a session's profiles into ``profiles``.
  /// - Parameter sessionID: The session.
  public func loadProfiles(sessionID: String) async {
    do {
      profiles[sessionID] = try await connector.profiles(sessionID: sessionID)
    } catch {
      lastError = String(describing: error)
    }
  }

  /// Creates a remote tab.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - url: The first page.
  ///   - profile: The profile.
  /// - Returns: The tab and its record, or `nil` with ``lastError`` set.
  public func open(sessionID: String, url: String?, profile: String?) async
    -> (tab: RemoteBrowserTab, record: RemoteBrowserTabRecord)?
  {
    do {
      let tab = try await connector.createTab(sessionID: sessionID, url: url, profile: profile)
      lastError = nil
      return (tab, RemoteBrowserTabRecord(url: tab.url, profile: tab.profile))
    } catch let error as CoreError {
      lastError = error.remoteBrowserMessage
      return nil
    } catch {
      lastError = String(describing: error)
      return nil
    }
  }

  /// Detaches a tab's store and closes the remote tab, unless it already ended.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The tab.
  /// - Throws: The connector's error; the local store is detached either way.
  public func close(sessionID: String, tabID: String) async throws {
    let store = stores.removeValue(forKey: Self.key(sessionID, tabID))
    store?.detach()
    guard store?.isEnded != true else { return }
    try await connector.closeTab(sessionID: sessionID, tabID: tabID)
  }

  /// Detaches a tab's store but keeps the remote tab (the local tab moved to another window).
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - tabID: The tab.
  public func detach(sessionID: String, tabID: String) {
    stores.removeValue(forKey: Self.key(sessionID, tabID))?.detach()
  }

  /// Detaches every store (the window closed); remote tabs stay open.
  public func detachAll() {
    for store in stores.values { store.detach() }
    stores.removeAll()
  }

  private static func key(_ sessionID: String, _ tabID: String) -> String {
    "\(sessionID)/\(tabID)"
  }
}
