import Foundation

// `isHostOnline` mirrors the core's tri-state liveness: `nil` is "not reported", never offline.
// swiftlint:disable discouraged_optional_boolean

/// Where a session runs, for the composer's execution-context row:
/// `Codex · Mac Studio · omnigent / auth-refresh`, with the server, host, sandbox and directory
/// on demand.
nonisolated public struct ExecutionContext: Hashable, Sendable {
  /// The agent (harness) name, for example "Codex".
  public var agent: String?
  /// The harness id, for its glyph.
  public var harness: String?
  /// The execution host's display name.
  public var host: String?
  /// Cloud sandbox or one of the user's machines.
  public var hostKind: ComposerHost.Kind
  /// The host is online; `nil` when not reported.
  public var isHostOnline: Bool?
  /// The server's display name (see ``serverDisplayName(name:baseURL:)``).
  public var server: String?
  /// The working directory.
  public var directory: String?
  /// The git branch.
  public var branch: String?
  /// The sandbox the agent runs in, for example "None (runs on the host)".
  public var sandbox: String?
  /// Why nothing can run there now, shown before the first send.
  public var unavailableReason: String?

  /// Creates a context.
  /// - Parameters:
  ///   - agent: Agent name.
  ///   - harness: Harness id.
  ///   - host: Host display name.
  ///   - hostKind: Cloud or machine.
  ///   - isHostOnline: Host online.
  ///   - server: Server display name.
  ///   - directory: Working directory.
  ///   - branch: Git branch.
  ///   - sandbox: Sandbox description.
  ///   - unavailableReason: Why it cannot run.
  public init(
    agent: String? = nil, harness: String? = nil, host: String? = nil,
    hostKind: ComposerHost.Kind = .machine, isHostOnline: Bool? = nil, server: String? = nil,
    directory: String? = nil, branch: String? = nil, sandbox: String? = nil,
    unavailableReason: String? = nil
  ) {
    self.agent = agent
    self.harness = harness
    self.host = host
    self.hostKind = hostKind
    self.isHostOnline = isHostOnline
    self.server = server
    self.directory = directory
    self.branch = branch
    self.sandbox = sandbox
    self.unavailableReason = unavailableReason
  }

  /// The directory's last path component.
  public var repository: String? {
    guard let directory = Self.nonEmpty(directory) else { return nil }
    let name = URL(filePath: directory).lastPathComponent
    return name.isEmpty || name == "/" ? directory : name
  }

  /// `repository / branch`, either alone, or `nil`.
  public var workspace: String? {
    switch (repository, Self.nonEmpty(branch)) {
    case (let repository?, let branch?): "\(repository) / \(branch)"
    case (let repository?, nil): repository
    case (nil, let branch?): branch
    case (nil, nil): nil
    }
  }

  /// `agent · host · repository / branch`, skipping what is unknown.
  /// - Parameter includingWorkspace: Include the workspace (off where a folder picker shows it).
  /// - Returns: The line.
  public func summary(includingWorkspace: Bool = true) -> String {
    let parts = [Self.nonEmpty(agent), Self.nonEmpty(host), includingWorkspace ? workspace : nil]
      .compactMap(\.self)
    return parts.isEmpty ? "Execution context" : parts.joined(separator: " \u{00B7} ")
  }

  /// The server's name to show: the manifest's `server_name`, else the URL's host, and never a
  /// loopback address ("This Mac").
  /// - Parameters:
  ///   - name: The manifest's display name.
  ///   - baseURL: The server's API root.
  /// - Returns: The name.
  public static func serverDisplayName(name: String?, baseURL: String?) -> String {
    if let name = nonEmpty(name), !isLoopback(name) { return name }
    guard let baseURL, let components = URLComponents(string: baseURL),
      let host = nonEmpty(components.host)
    else { return nonEmpty(name).map { _ in thisDevice } ?? "Connected server" }
    if isLoopback(host) { return thisDevice }
    return components.port.map { "\(host):\($0)" } ?? host
  }

  /// A host's name to show; a loopback address reads "This Mac".
  /// - Parameter name: The reported name.
  /// - Returns: The name, or `nil` when empty.
  public static func hostDisplayName(_ name: String?) -> String? {
    guard let name = nonEmpty(name) else { return nil }
    return isLoopback(name) ? thisDevice : name
  }

  /// `localhost`, `127.0.0.0/8`, `::1` or `0.0.0.0`, bracketed or not.
  static func isLoopback(_ host: String) -> Bool {
    let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" || bare == "0.0.0.0" {
      return true
    }
    let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets.first == "127"
      && octets.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
  }

  private static var thisDevice: String {
    #if os(macOS)
      "This Mac"
    #else
      "This device"
    #endif
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}

// swiftlint:enable discouraged_optional_boolean
