import Foundation
public import Observation

/// Whether the open session's agent can take a message now, from the runner and host signals
/// (the web's `useSessionLiveness`). Each case has one affordance: nothing, a passive
/// "Connecting…", a quiet asleep line, or a reconnect row with the reconnect sheet.
nonisolated public enum SessionLiveness: Hashable, Sendable {
  /// The runner is connected.
  case online
  /// A just-sent turn is waking the runner or a resumable host.
  case starting
  /// The runner is down but its host (or resumable managed host) wakes it on the next message.
  case asleep
  /// The session's host is offline and only its owner can bring it back.
  case hostOffline(isOwner: Bool)
  /// No host is bound and the runner is down: it is restarted from the machine that ran it.
  case stranded
  /// Liveness is not reported yet; treated as online.
  case unknown

  // swiftlint:disable discouraged_optional_boolean
  /// What liveness is derived from, as the session reports it.
  public struct Signals: Hashable, Sendable {
    /// The runner tunnel is registered; `nil` until reported.
    public var runnerOnline: Bool?
    /// The host tunnel is up; `nil` until reported.
    public var hostOnline: Bool?
    /// The bound host.
    public var hostID: String?
    /// The host is a managed host the server wakes on the next message.
    public var hostResumable = false
    /// A turn is running or waiting to start.
    public var isTurnActive = false
    /// A sub-agent session, which recovers through its parent.
    public var isSubagent = false
    /// The viewer owns the session.
    public var isOwner = true

    /// Creates the signals; the rest default to an idle, owned, top-level session.
    /// - Parameters:
    ///   - runnerOnline: The runner tunnel is registered, when reported.
    ///   - hostOnline: The host tunnel is up, when reported.
    ///   - hostID: The bound host.
    public init(runnerOnline: Bool?, hostOnline: Bool?, hostID: String?) {
      self.runnerOnline = runnerOnline
      self.hostOnline = hostOnline
      self.hostID = hostID
    }
  }
  // swiftlint:enable discouraged_optional_boolean

  /// The session's liveness, the first matching rule of the web's truth table.
  /// - Parameter signals: What the session reports.
  /// - Returns: The liveness.
  public static func derive(_ signals: Signals) -> Self {
    if signals.runnerOnline == true { return .online }
    let hasHost = !(signals.hostID ?? "").isEmpty
    if hasHost, signals.hostOnline == false {
      if signals.hostResumable { return signals.isTurnActive ? .starting : .asleep }
      return .hostOffline(isOwner: signals.isOwner)
    }
    guard signals.runnerOnline == false else { return .unknown }
    if signals.hostOnline == true || signals.isSubagent {
      return signals.isTurnActive ? .starting : .asleep
    }
    return hasHost ? .unknown : .stranded
  }

  /// The host is gone or the agent is stranded: the user has to act.
  public var isUnreachable: Bool {
    switch self {
    case .hostOffline, .stranded: true
    default: false
    }
  }
}

/// The liveness line under the composer and, for an unreachable session, what the reconnect
/// sheet shows (the web's `ReconnectSessionDialog`).
nonisolated public struct SessionLivenessNotice: Hashable, Sendable {
  /// The session's liveness.
  public var liveness: SessionLiveness
  /// The command the user runs on the machine, `nil` when they cannot reach it.
  public var command: String?

  /// Creates the notice.
  /// - Parameters:
  ///   - liveness: The session's liveness.
  ///   - sessionID: The session.
  ///   - serverURL: The server, as the CLI's `--server`.
  ///   - wrapper: The session's `omnigent.wrapper` label.
  ///   - harness: The session's harness.
  public init(
    liveness: SessionLiveness, sessionID: String, serverURL: String, wrapper: String?,
    harness: String?
  ) {
    self.liveness = liveness
    switch liveness {
    case .hostOffline(let isOwner):
      command = isOwner ? Self.hostCommand(serverURL: serverURL) : nil
    case .stranded:
      command = Self.resumeCommand(
        sessionID: sessionID, serverURL: serverURL,
        agent: Self.nativeAgent(wrapper: wrapper, harness: harness))
    default:
      command = nil
    }
  }

  /// The asleep or starting line, `nil` when the session is unreachable or online.
  public var line: String? {
    switch liveness {
    case .starting: "Connecting\u{2026}"
    case .asleep: "Agent is asleep \u{2014} send a message to reconnect"
    default: nil
    }
  }

  /// "Host is offline" or "Agent disconnected", the web's titles.
  public var title: String {
    if case .hostOffline = liveness { return "Host is offline" }
    return "Agent disconnected"
  }

  /// What to do, in the user's terms.
  public var message: String {
    switch liveness {
    case .hostOffline(isOwner: true):
      "This session\u{2019}s host is offline. Run the command below from the host machine to reconnect."
    case .hostOffline(isOwner: false):
      "This session\u{2019}s host is offline. Only its owner can reconnect it. Fork the session to continue in a copy you own."
    default:
      "Run the command below from the machine where you started this session to reconnect."
    }
  }

  /// The CLI verbs of the native terminal harnesses, which resume through their own verb.
  static let nativeAgents = [
    "claude", "codex", "opencode", "devin", "cursor", "pi", "kiro", "antigravity", "goose",
    "qwen", "kimi", "hermes",
  ]

  /// The native agent verb for a wrapper label (`codex-native-ui`, `claude-code-native-ui`)
  /// or, without one, a harness (`codex-native`, `native-pi`, `agy-native`).
  static func nativeAgent(wrapper: String?, harness: String?) -> String? {
    if let wrapper {
      if wrapper == "claude-code-native-ui" { return "claude" }
      if let agent = nativeAgents.first(where: { "\($0)-native-ui" == wrapper }) { return agent }
    }
    guard let harness else { return nil }
    if harness == "agy-native" || harness == "native-agy" { return "antigravity" }
    return nativeAgents.first { harness == "\($0)-native" || harness == "native-\($0)" }
  }

  static func hostCommand(serverURL: String) -> String {
    "omnigent host \\\n  --server \(quoted(serverURL))"
  }

  static func resumeCommand(sessionID: String, serverURL: String, agent: String?) -> String {
    let verb = agent.map { "omnigent \($0)" } ?? "omnigent run path/to/agent.yaml"
    return "\(verb) \\\n  --resume \(quoted(sessionID)) \\\n  --server \(quoted(serverURL))"
  }

  /// Single-quotes a shell argument unless it is plainly safe.
  static func quoted(_ argument: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:@%+=,"))
    if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
    return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

/// What the reconnect sheet can do.
public struct SessionLivenessActions {
  /// Re-reads the session's liveness.
  public var checkAgain: (@MainActor () -> Void)?
  /// Opens the fork sheet, to continue in a copy.
  public var fork: (@MainActor () -> Void)?
  /// Moves the session to another online host (owners of a session whose host is offline).
  public var switchHost: HostMoveRoute?
  /// Starts a session bound to no host on one of the user's machines.
  public var resume: HostMoveRoute?
  /// Which sheet shows, kept by the conversation so a send can open Resume on a Machine;
  /// `nil` keeps it in the row.
  public var sheets: SessionLivenessSheets?

  /// Creates the actions.
  /// - Parameters:
  ///   - checkAgain: Re-read liveness.
  ///   - fork: Fork the session.
  public init(checkAgain: (@MainActor () -> Void)? = nil, fork: (@MainActor () -> Void)? = nil) {
    self.checkAgain = checkAgain
    self.fork = fork
  }
}

/// A Switch Host or Resume on a Machine sheet the liveness row can open.
public struct HostMoveRoute {
  /// The sheet.
  public var kind: HostMoveKind
  /// What it reads and does.
  public var actions: HostMoveActions

  /// Creates a route.
  /// - Parameters:
  ///   - kind: The sheet.
  ///   - actions: What it reads and does.
  public init(kind: HostMoveKind, actions: HostMoveActions) {
    self.kind = kind
    self.actions = actions
  }
}

/// A sheet over the liveness row.
nonisolated public enum SessionLivenessSheet: String, Hashable, Sendable, Identifiable {
  /// How to reconnect.
  case reconnect
  /// Move to another host.
  case switchHost
  /// Start on one of the user's machines.
  case resume

  /// The case.
  public var id: String { rawValue }
}

/// The liveness row's open sheet.
@MainActor
@Observable
public final class SessionLivenessSheets {
  /// The sheet showing, if any.
  public var shown: SessionLivenessSheet? {
    didSet { if shown == nil { sendsDraftOnResume = false } }
  }
  /// A send opened Resume on a Machine: the draft goes once the session starts; closing the
  /// sheet keeps the draft unsent.
  @ObservationIgnored public var sendsDraftOnResume = false

  /// Creates the presenter with nothing showing.
  public init() {}
}
