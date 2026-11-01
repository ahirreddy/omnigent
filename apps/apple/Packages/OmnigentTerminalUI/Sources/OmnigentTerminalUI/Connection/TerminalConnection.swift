import Foundation

/// A terminal grid size in character cells.
public struct TerminalGridSize: Hashable, Sendable, CustomStringConvertible {
  /// Columns.
  public let columns: Int
  /// Rows.
  public let rows: Int

  /// A grid size. Both dimensions must be at least 1.
  public init?(columns: Int, rows: Int) {
    guard columns > 0, rows > 0 else { return nil }
    self.columns = columns
    self.rows = rows
  }

  /// A readable description.
  public var description: String { "\(columns)x\(rows)" }
}

/// Why an attach closed without an error. Mirrors the core's `ClosedReason`.
public enum TerminalCloseReason: Hashable, Sendable {
  /// The terminal's process exited or the terminal was deleted (close code 4404).
  case terminalEnded(reason: String)
  /// This attach was detached; the terminal still runs (4405).
  case detached(reason: String)
  /// The server closed the attach on purpose with another code.
  case serverClosed(code: Int, reason: String)
  /// The user detached.
  case stopped
}

/// A failure that stops the attach until it is started again. Mirrors the core's
/// `AttachFailure` with its user-facing message.
public struct TerminalFailure: Hashable, Sendable, Error, CustomStringConvertible {
  /// What went wrong, for the user.
  public let message: String
  /// The user must sign in again.
  public let requiresSignIn: Bool
  /// An interactive attach was denied; a read-only attach may still work.
  public let readOnlyMayWork: Bool

  /// A failure.
  public init(message: String, requiresSignIn: Bool = false, readOnlyMayWork: Bool = false) {
    self.message = message
    self.requiresSignIn = requiresSignIn
    self.readOnlyMayWork = readOnlyMayWork
  }

  /// A readable description.
  public var description: String { message }
}

/// The attach state the terminal view shows. Mirrors the core's `AttachState`.
public enum TerminalConnectionState: Hashable, Sendable {
  /// Not started.
  case idle
  /// The first attempt is in flight.
  case connecting
  /// Streaming.
  case attached(readOnly: Bool)
  /// The connection dropped; another attempt is pending or in flight.
  case reconnecting(failures: Int, retryInMilliseconds: Int, reason: String)
  /// The attach ended without an error.
  case closed(TerminalCloseReason)
  /// The attach failed.
  case failed(TerminalFailure)

  /// Whether keystrokes reach the terminal in this state.
  public var acceptsInput: Bool {
    if case .attached(let readOnly) = self { return !readOnly }
    return false
  }
}

/// One item for the renderer, in order.
public enum TerminalOutput: Hashable, Sendable {
  /// Pane output bytes, exactly as received.
  case bytes([UInt8])
  /// A reattach is starting: clear the screen and scrollback before the next bytes, which are
  /// the server's seed of the current screen.
  case resetScreen
  /// The remote program copied text (tmux copy mode). Offer it to the local clipboard; never
  /// write it without the user's consent.
  case clipboardWrite(String)
}

/// The I/O surface of one attached terminal: either a session shell or the session's harness TUI.
///
/// The app implements this with the core's `TerminalAttach` state machine driving the URLSession
/// WebSocket transport. Previews and tests use ``EchoTerminalConnection`` and
/// ``ReplayTerminalConnection``.
///
/// Contract:
/// - ``output`` and ``states`` are each iterated by exactly one consumer, the
///   ``TerminalSurfaceController`` that renders this connection, for the connection's lifetime.
///   A connection is attached to at most one controller.
/// - ``send(_:)`` takes bytes already encoded by the renderer (keys, IME commits, paste, mouse
///   reports). The connection forwards them as one binary frame each, or reports them dropped
///   through its state (never buffering them for a later attach).
/// - ``resize(_:)`` reports the renderer's grid. The connection sends it when it changes and
///   again on every new attach, before any input.
/// - ``start()`` attaches (or reattaches after a close or failure); ``stop()`` detaches.
///   ``foreground()`` is called when the app or window becomes visible, so a pending
///   reconnect can run at once.
@MainActor
public protocol TerminalConnection: AnyObject {
  /// Renderer input, in order.
  var output: AsyncStream<TerminalOutput> { get }
  /// State changes, starting with the current state.
  var states: AsyncStream<TerminalConnectionState> { get }
  /// The current state.
  var state: TerminalConnectionState { get }
  /// Sends encoded input bytes.
  func send(_ bytes: [UInt8])
  /// Reports the renderer's grid size.
  func resize(_ size: TerminalGridSize)
  /// Attaches.
  func start()
  /// Detaches.
  func stop()
  /// The app or window became visible.
  func foreground()
}
