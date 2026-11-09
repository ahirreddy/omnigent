public import Observation
import OmnigentCoreFFI
public import OmnigentStores
public import OmnigentTerminalUI

/// One session's terminal surfaces: one ``TerminalSurfaceController`` per terminal, kept alive
/// across view changes (a Chat/Terminal switch, the terminal list) so the screen and scrollback
/// survive. The terminal list and the harness view come from ``terminals``.
///
/// Keep one store per open session (for example next to its `ConversationStore`) and release it
/// when the session closes; releasing it detaches every terminal.
@Observable
public final class TerminalStore {
  /// The session's terminal list and harness view.
  public let terminals: SessionTerminalsStore
  /// Surfaces by terminal id.
  public private(set) var controllers: [String: TerminalSurfaceController] = [:]
  /// The last surface failure (libghostty could not start or create the surface).
  public internal(set) var lastError: GhosttyError?

  @ObservationIgnored private let runtime: GhosttyRuntime?

  /// A store over `terminals`.
  /// - Parameters:
  ///   - terminals: The session's terminal list, from `ConnectionStore.terminals(_:)`.
  ///   - runtime: The libghostty runtime; the shared one when `nil`.
  public init(terminals: SessionTerminalsStore, runtime: GhosttyRuntime? = nil) {
    self.terminals = terminals
    self.runtime = runtime
  }

  /// The session.
  public var sessionID: String { terminals.sessionID }

  /// The surface of `terminalID`, creating (and starting) it on first use.
  /// - Parameters:
  ///   - terminalID: The terminal.
  ///   - permissionLevel: The caller's permission level on the session; below owner attaches
  ///     read-only.
  ///   - hostID: The session's host, for sharded routing.
  /// - Returns: The surface, or `nil` after recording the failure in ``lastError``.
  public func controller(for terminalID: String, permissionLevel: Int64?, hostID: String?)
    -> TerminalSurfaceController?
  {
    if let existing = controllers[terminalID] { return existing }
    let connection = CoreTerminalConnection(
      attach: terminals.attach(
        terminalID: terminalID, permissionLevel: permissionLevel, hostID: hostID))
    do {
      let controller = try TerminalSurfaceController(connection: connection, runtime: runtime)
      controllers[terminalID] = controller
      lastError = nil
      return controller
    } catch {
      lastError = error
      return nil
    }
  }

  /// The surface of the session's harness TUI, when the core reports it is ready.
  /// - Parameters:
  ///   - permissionLevel: The caller's permission level on the session.
  ///   - hostID: The session's host.
  /// - Returns: The surface, or `nil` when there is none yet (see `terminals.harness`).
  public func harnessController(permissionLevel: Int64?, hostID: String?)
    -> TerminalSurfaceController?
  {
    guard case .ready(let terminal) = terminals.harness else { return nil }
    return controller(for: terminal.id, permissionLevel: permissionLevel, hostID: hostID)
  }

  /// Detaches `terminalID` and drops its surface.
  /// - Parameter terminalID: The terminal.
  public func close(_ terminalID: String) {
    controllers.removeValue(forKey: terminalID)?.connection.stop()
  }

  /// The app or window became visible: pending reconnects run now.
  public func foreground() {
    for controller in controllers.values {
      controller.connection.foreground()
    }
  }
}
