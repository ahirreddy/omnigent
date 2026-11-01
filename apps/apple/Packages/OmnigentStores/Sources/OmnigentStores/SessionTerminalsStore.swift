import Foundation
public import Observation
public import OmnigentCoreFFI

/// One session's terminals, kept current by the core while the session is open (list reads,
/// `session.resource.*`, `session.terminal.activity` and the runner's `terminal_pending`), and
/// what its Terminal view can show.
@Observable
public final class SessionTerminalsStore {
  /// The session.
  public let sessionID: String
  /// Every terminal with its badge, oldest first.
  public private(set) var rows: [TerminalRow] = []
  /// What the session's Terminal view can show. `notTerminalFirst` until the core reports it.
  public private(set) var harness: HarnessTerminal = .notTerminalFirst
  /// The last failure of a call made here.
  public private(set) var lastError: CoreError?
  /// A create or delete is in flight.
  public private(set) var isBusy = false
  /// The terminal names the session's agent declares, in order: the only names ``create(_:)``
  /// accepts (for a native harness, the host's shells with `$SHELL` first). Empty when the agent
  /// declares none, and until ``knowsDeclaredTerminalNames``.
  public private(set) var declaredTerminalNames: [String] = []
  /// ``loadDeclaredTerminalNames()`` finished and the server reported the names. An older server
  /// that does not report them leaves this `false`.
  public private(set) var knowsDeclaredTerminalNames = false

  private let core: ClientCore

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// The user's shells: every terminal except the agent's own.
  public var userShells: [TerminalRow] { rows.filter { !$0.terminal.isAgentTerminal } }

  /// Re-reads the terminals; the result arrives through the core's events.
  public func refresh() {
    core.refreshTerminals(sessionId: sessionID)
  }

  /// Reads ``declaredTerminalNames`` from the session's agent. A failure is recorded in
  /// ``lastError`` and leaves the previous names.
  public func loadDeclaredTerminalNames() async {
    do {
      let names = try await core.declaredTerminalNames(sessionId: sessionID)
      declaredTerminalNames = names ?? []
      knowsDeclaredTerminalNames = names != nil
    } catch {
      lastError = coreError(error)
    }
  }

  /// Launches a terminal (for example a host shell such as `zsh`).
  /// - Parameter name: The declared terminal name.
  /// - Returns: The terminal, or `nil` after recording the failure in ``lastError``.
  @discardableResult
  public func create(_ name: String) async -> TerminalResource? {
    isBusy = true
    defer { isBusy = false }
    do {
      let terminal = try await core.createTerminal(sessionId: sessionID, terminalName: name)
      lastError = nil
      return terminal
    } catch {
      lastError = coreError(error)
      return nil
    }
  }

  /// Closes a terminal.
  /// - Parameter terminalID: The terminal.
  public func delete(_ terminalID: String) async {
    isBusy = true
    defer { isBusy = false }
    do {
      _ = try await core.deleteTerminal(sessionId: sessionID, terminalId: terminalID)
      lastError = nil
    } catch {
      lastError = coreError(error)
    }
  }

  /// An attach to `terminalID`, idle until started. A caller below owner `permissionLevel`
  /// attaches read-only; `hostID` routes the socket on sharded deployments.
  /// - Parameters:
  ///   - terminalID: The terminal.
  ///   - permissionLevel: The caller's permission level on the session, if known.
  ///   - hostID: The session's host.
  /// - Returns: The attach.
  public func attach(terminalID: String, permissionLevel: Int64?, hostID: String?)
    -> TerminalAttach
  {
    TerminalAttach(
      core: core, sessionID: sessionID, terminalID: terminalID,
      permissionLevel: permissionLevel, hostID: hostID)
  }

  /// Clears ``lastError`` after the user has seen it.
  public func dismissError() {
    lastError = nil
  }

  func apply(terminals: [TerminalRow], harness: HarnessTerminal) {
    rows = terminals
    self.harness = harness
  }
}

/// One event from a terminal attach, in order.
public enum TerminalAttachEvent: Equatable, Sendable {
  /// The attach state changed.
  case state(TerminalAttachState)
  /// Pane output bytes.
  case output([UInt8])
  /// A reattach is starting: clear the screen before the next output.
  case resetScreen
  /// The remote program copied text; offer it to the clipboard with the user's consent.
  case clipboardWrite(String)
  /// Input was not sent (never buffered for later).
  case inputDropped(byteCount: UInt64, reason: TerminalInputDropReason)
  /// A frame the client could not use; the attach continues.
  case notice(String)
}

/// Forwards attach callbacks, in order, from the core's thread into one stream.
nonisolated final class TerminalAttachRelay: TerminalAttachListener, Sendable {
  let events: AsyncStream<TerminalAttachEvent>
  private let continuation: AsyncStream<TerminalAttachEvent>.Continuation

  init() {
    (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
  }

  func onState(state: TerminalAttachState) { continuation.yield(.state(state)) }
  func onOutput(bytes: Data) { continuation.yield(.output(Array(bytes))) }
  func onResetScreen() { continuation.yield(.resetScreen) }
  func onClipboardWrite(text: String) { continuation.yield(.clipboardWrite(text)) }
  func onInputDropped(byteCount: UInt64, reason: TerminalInputDropReason) {
    continuation.yield(.inputDropped(byteCount: byteCount, reason: reason))
  }
  func onNotice(message: String) { continuation.yield(.notice(message)) }

  func finish() { continuation.finish() }
}

/// One terminal attach driven by the core's `TerminalAttach` machine. ``events`` has exactly
/// one consumer: iterate it once, for the attach's lifetime. Releasing the attach detaches.
public final class TerminalAttach {
  /// The session.
  public let sessionID: String
  /// The terminal.
  public let terminalID: String
  /// Every event, in order. Exactly one consumer.
  public let events: AsyncStream<TerminalAttachEvent>

  private let driver: TerminalAttachDriver
  private let relay: TerminalAttachRelay

  init(
    core: ClientCore, sessionID: String, terminalID: String, permissionLevel: Int64?,
    hostID: String?
  ) {
    let relay = TerminalAttachRelay()
    self.relay = relay
    self.sessionID = sessionID
    self.terminalID = terminalID
    events = relay.events
    driver = core.terminalAttach(
      sessionId: sessionID, terminalId: terminalID, permissionLevel: permissionLevel,
      hostId: hostID, listener: relay)
  }

  isolated deinit {
    driver.stop()
    relay.finish()
  }

  /// Attaches (or reattaches after a close or failure).
  public func start() { driver.start() }

  /// Detaches.
  public func stop() { driver.stop() }

  /// The app or window became visible: a pending reconnect runs now.
  public func foreground() { driver.foreground() }

  /// Sends encoded input bytes as one binary frame.
  /// - Parameter bytes: The bytes.
  public func send(_ bytes: [UInt8]) { driver.sendInput(bytes: Data(bytes)) }

  /// Reports the renderer's grid size.
  /// - Parameters:
  ///   - columns: Columns.
  ///   - rows: Rows.
  /// - Throws: ``CoreError`` for a zero or oversized dimension.
  public func resize(columns: UInt16, rows: UInt16) throws(CoreError) {
    do {
      try driver.resize(cols: columns, rows: rows)
    } catch {
      throw coreError(error)
    }
  }
}
