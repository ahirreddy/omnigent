import Foundation
public import OmnigentCoreFFI
import Synchronization

/// Errors from the fixture host.
nonisolated public enum FixtureRemoteBrowserError: Error, Hashable, Sendable,
  CustomStringConvertible
{
  /// The tab does not exist.
  case tabNotFound(String)

  /// A readable message.
  public var description: String {
    switch self {
    case .tabNotFound(let id): "The remote tab \(id) does not exist."
    }
  }
}

/// A stand-in remote browser host for previews, the playground, the gallery and tests: it keeps
/// tabs in memory and plays the recorded H.264 fixtures as their video. Tabs it does not know
/// (for example after a relaunch) attach and then close, as a host reports a tab that is gone.
public final class FixtureRemoteBrowser: RemoteBrowserConnecting {
  /// One host for the process, so tabs survive moving between windows.
  public static let shared = FixtureRemoteBrowser()

  private struct Tab: Sendable {
    var url: String
    var profile: String
  }

  private let tabs = Mutex<[String: Tab]>([:])
  private let profileList: [RemoteBrowserProfile]
  private let latency: Duration
  private let resources: Bundle

  /// Creates a host.
  /// - Parameters:
  ///   - profiles: The machine's profiles.
  ///   - latency: Simulated connect and request latency.
  public nonisolated convenience init(
    profiles: [RemoteBrowserProfile] = [
      RemoteBrowserProfile(name: "default", running: true),
      RemoteBrowserProfile(name: "work", running: false),
    ],
    latency: Duration = .milliseconds(120)
  ) {
    self.init(profiles: profiles, latency: latency, resources: .module)
  }

  /// A host playing the streams in `resources`, so a test can leave some out.
  nonisolated init(profiles: [RemoteBrowserProfile], latency: Duration, resources: Bundle) {
    profileList = profiles
    self.latency = latency
    self.resources = resources
  }

  /// Adds a tab directly, for scenarios that start with one open.
  /// - Parameters:
  ///   - id: The tab id.
  ///   - url: Its URL.
  ///   - profile: Its profile.
  public nonisolated func addTab(id: String, url: String, profile: String = "default") {
    tabs.withLock { $0[id] = Tab(url: url, profile: profile) }
  }

  /// The profiles.
  public nonisolated func profiles(sessionID: String) async throws -> [RemoteBrowserProfile] {
    try await Task.sleep(for: latency)
    return profileList
  }

  /// Creates a tab.
  public nonisolated func createTab(sessionID: String, url: String?, profile: String?)
    async throws -> RemoteBrowserTab
  {
    try await Task.sleep(for: latency)
    let id = "btab_" + UUID().uuidString.prefix(8).lowercased()
    let tab = Tab(url: url ?? "https://example.com/", profile: profile ?? "default")
    tabs.withLock { $0[id] = tab }
    let title = Self.title(for: tab.url)
    return RemoteBrowserTab(
      id: id, sessionId: sessionID, name: title, url: tab.url, title: title, loading: true,
      owner: .user, needsAttention: false, profile: tab.profile, createdBy: .user,
      canGoBack: false, canGoForward: false, thumbnailUrl: nil)
  }

  /// Closes a tab.
  public nonisolated func closeTab(sessionID: String, tabID: String) async throws {
    try await Task.sleep(for: latency)
    let removed = tabs.withLock { $0.removeValue(forKey: tabID) }
    guard removed != nil else { throw FixtureRemoteBrowserError.tabNotFound(tabID) }
  }

  /// Attaches to a tab.
  public nonisolated func attach(
    sessionID: String, tabID: String, mode: RemoteBrowserMode, hostID: String?,
    listener: any RemoteBrowserListener
  ) -> any RemoteBrowserDriverProtocol {
    let tab = tabs.withLock { $0[tabID] }
    var start = RemoteBrowserSnapshot.initial(url: tab?.url ?? "", profile: tab?.profile ?? "")
    start.nav?.title = tab.map { Self.title(for: $0.url) } ?? ""
    start.mode = mode
    return FixtureRemoteBrowserDriver(
      start: start, tabExists: tab != nil, latency: latency, resources: resources,
      listener: listener)
  }

  /// A page title for a fixture URL: its host without `www.`.
  /// - Parameter url: The URL.
  /// - Returns: The title.
  public nonisolated static func title(for url: String) -> String {
    guard var host = URL(string: url)?.host(), !host.isEmpty else { return url }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    return host
  }
}
