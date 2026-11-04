#if os(macOS)
  import Foundation
  public import OmnigentAuthUI
  public import OmnigentDesktop

  /// "Get started locally" over the app's ``LocalServerManager``: the CLI and server state for
  /// the setup screens, starting (or reusing) the server and connecting the window to it, and
  /// hosting for a joined server once signed in, as Server > Start Host on This Mac does.
  public final class LocalServerSetup: LocalSetupSource {
    /// How many output lines the progress screen shows.
    static let logLines = 12

    private let manager: LocalServerManager
    private let showLogs: (@MainActor () -> Void)?
    /// The server the user asked this Mac to host for, until the window signs in to it.
    private(set) var pendingHost: String?

    /// Creates the setup, or `nil` when this edition cannot run local processes.
    /// - Parameters:
    ///   - manager: The app's local server manager.
    ///   - showLogs: Opens the Server Logs window.
    public init?(manager: LocalServerManager, showLogs: (@MainActor () -> Void)? = nil) {
      guard manager.capability.isAvailable else { return nil }
      self.manager = manager
      self.showLogs = showLogs
      // The landing's action depends on whether the CLI is installed.
      if manager.cli == .notChecked {
        Task { await manager.refreshCLI() }
      }
    }

    /// The CLI and server as the setup screens show them.
    public var state: LocalSetupState {
      Self.state(cli: manager.cli, server: manager.server, log: recentLog)
    }

    private var recentLog: [String] {
      manager.serverLog.lines.suffix(Self.logLines).map(\.text)
    }

    /// The setup screens' actions.
    public func actions(connect: @escaping @MainActor (String) -> Void) -> LocalSetupActions {
      LocalSetupActions(
        start: { [weak self] in self?.start(connect: connect) },
        recheckCLI: { [weak self] in
          guard let manager = self?.manager else { return }
          Task { await manager.refreshCLI() }
        },
        hostAfterSignIn: { [weak self] url in self?.pendingHost = url },
        showLogs: showLogs)
    }

    /// Hosts for `baseUrl` when the user chose this Mac for it before signing in.
    public func didSignIn(to baseUrl: String) {
      guard let pending = pendingHost, Self.sameServer(pending, baseUrl) else { return }
      pendingHost = nil
      guard let url = URL(string: baseUrl) else { return }
      Task { await manager.startHost(serverURL: url) }
    }

    /// Opens a running server, or starts one and connects once it is ready. A failure stays on
    /// the manager's state, which the progress screen shows.
    private func start(connect: @escaping @MainActor (String) -> Void) {
      if let endpoint = manager.server.endpoint {
        connect(endpoint.url.absoluteString)
        return
      }
      let manager = manager
      Task {
        await manager.startServer(trigger: .window)
        if let endpoint = manager.server.endpoint { connect(endpoint.url.absoluteString) }
      }
    }

    /// Maps the manager's state onto the setup screens'.
    /// - Parameters:
    ///   - cli: The CLI lookup.
    ///   - server: The server.
    ///   - log: Recent output lines.
    /// - Returns: The screens' state.
    nonisolated static func state(cli: LocalCLIState, server: LocalServerStatus, log: [String])
      -> LocalSetupState
    {
      let cliState: LocalSetupState.CLI =
        switch cli {
        case .notChecked, .checking: .checking
        case .found: .found
        case .missing(let error): .missing(error.message)
        }
      let serverState: LocalSetupState.Server =
        switch server {
        case .running(let endpoint, _): .running(url: endpoint.url.absoluteString)
        case .stopped: .stopped
        case .unavailable: .failed(server.summary)
        case .checking, .starting, .stopping: .busy(server.summary)
        case .crashed(_, nil): .failed(server.summary)
        case .crashed: .busy(server.summary)
        case .failed(let error): .failed(error.message)
        }
      return LocalSetupState(cli: cliState, server: serverState, log: log)
    }

    /// Two server URLs share an origin. The typed URL and the server's canonical API root can
    /// differ in their mount path.
    nonisolated static func sameServer(_ lhs: String, _ rhs: String) -> Bool {
      func origin(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host else {
          return nil
        }
        return "\(components.scheme ?? "")://\(host.lowercased()):\(components.port ?? -1)"
      }
      guard let left = origin(lhs) else { return false }
      return left == origin(rhs)
    }
  }
#endif
