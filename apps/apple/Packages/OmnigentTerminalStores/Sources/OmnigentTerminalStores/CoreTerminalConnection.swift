public import Observation
public import OmnigentCoreFFI
public import OmnigentStores
public import OmnigentTerminalUI

/// A ``TerminalConnection`` backed by the core's terminal attach (`TerminalAttachDriver`).
///
/// One task consumes the attach's event stream and feeds ``output`` and ``states``; each of
/// those has exactly one consumer, the ``TerminalSurfaceController`` rendering this connection.
@Observable
public final class CoreTerminalConnection: TerminalConnection {
  /// Renderer input, in order. Exactly one consumer.
  public let output: AsyncStream<TerminalOutput>
  /// State changes, starting with the current state. Exactly one consumer.
  public let states: AsyncStream<TerminalConnectionState>
  /// The current state.
  public private(set) var state: TerminalConnectionState = .idle
  /// Bytes of input that were not sent because the attach was not open or read-only. Input is
  /// never buffered for a later attach.
  public private(set) var droppedInputBytes: UInt64 = 0
  /// Frames the client could not use, and resize failures, newest last. Never dropped silently.
  public private(set) var notices: [String] = []

  /// The session.
  public var sessionID: String { attach.sessionID }
  /// The terminal.
  public var terminalID: String { attach.terminalID }

  @ObservationIgnored private let attach: TerminalAttach
  @ObservationIgnored private let outputContinuation: AsyncStream<TerminalOutput>.Continuation
  @ObservationIgnored private let stateContinuation:
    AsyncStream<TerminalConnectionState>.Continuation
  @ObservationIgnored private var pump: Task<Void, Never>?

  /// A connection over `attach`, which must not be consumed elsewhere.
  /// - Parameter attach: The core attach.
  public init(attach: TerminalAttach) {
    self.attach = attach
    (output, outputContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    stateContinuation.yield(.idle)
    let events = attach.events
    pump = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        self.handle(event)
      }
    }
  }

  isolated deinit {
    pump?.cancel()
    outputContinuation.finish()
    stateContinuation.finish()
  }

  /// Sends encoded input bytes as one binary frame.
  /// - Parameter bytes: The bytes.
  public func send(_ bytes: [UInt8]) {
    attach.send(bytes)
  }

  /// Reports the renderer's grid size.
  /// - Parameter size: The grid.
  public func resize(_ size: TerminalGridSize) {
    do {
      try attach.resize(
        columns: UInt16(clamping: size.columns), rows: UInt16(clamping: size.rows))
    } catch {
      note("Could not resize the terminal to \(size): \(error.message)")
    }
  }

  /// Attaches.
  public func start() { attach.start() }

  /// Detaches.
  public func stop() { attach.stop() }

  /// The app or window became visible.
  public func foreground() { attach.foreground() }

  /// Clears ``notices`` after the user has seen them.
  public func dismissNotices() { notices = [] }

  private func handle(_ event: TerminalAttachEvent) {
    switch event {
    case .state(let core):
      let mapped = Self.state(core)
      guard mapped != state else { return }
      state = mapped
      stateContinuation.yield(mapped)
    case .output(let bytes):
      outputContinuation.yield(.bytes(bytes))
    case .resetScreen:
      outputContinuation.yield(.resetScreen)
    case .clipboardWrite(let text):
      outputContinuation.yield(.clipboardWrite(text))
    case .inputDropped(let byteCount, _):
      droppedInputBytes += byteCount
    case .notice(let message):
      note(message)
    }
  }

  private func note(_ message: String) {
    notices.append(message)
    if notices.count > 50 { notices.removeFirst(notices.count - 50) }
  }

  /// The view's state for a core attach state.
  /// - Parameter state: The core state.
  /// - Returns: The view state.
  nonisolated public static func state(_ state: TerminalAttachState) -> TerminalConnectionState {
    switch state {
    case .idle: .idle
    case .connecting: .connecting
    case .attached(let readOnly): .attached(readOnly: readOnly)
    case .reconnecting(let reason, let failures, let delayMs):
      .reconnecting(
        failures: Int(failures), retryInMilliseconds: Int(clamping: delayMs),
        reason: reason.message)
    case .closed(let reason): .closed(closeReason(reason))
    case .stopped: .closed(.stopped)
    case .failed(let failure, let message, let requiresSignIn):
      .failed(failureState(failure, message: message, requiresSignIn: requiresSignIn))
    }
  }

  nonisolated private static func closeReason(_ reason: TerminalClosedReason)
    -> TerminalCloseReason
  {
    switch reason {
    case .terminalEnded(let reason): .terminalEnded(reason: reason)
    case .detached(let reason): .detached(reason: reason)
    case .serverClosed(let code, let reason): .serverClosed(code: Int(code), reason: reason)
    }
  }

  nonisolated private static func failureState(
    _ failure: TerminalAttachFailure, message: String, requiresSignIn: Bool
  ) -> TerminalFailure {
    var readOnlyMayWork = false
    if case .accessDenied(_, let readOnly) = failure { readOnlyMayWork = !readOnly }
    return TerminalFailure(
      message: message, requiresSignIn: requiresSignIn, readOnlyMayWork: readOnlyMayWork)
  }
}
