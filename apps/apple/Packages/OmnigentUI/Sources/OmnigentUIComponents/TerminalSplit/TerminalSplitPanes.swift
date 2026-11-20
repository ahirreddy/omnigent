public import Foundation
public import Observation
import os

/// One session's split Terminal view (`splittable_terminal_view_ui`), kept on this device per
/// session as the web keeps it per browser. Shared by the toolbar's split actions and the view.
@Observable
public final class TerminalSplitPanes {
  /// The session.
  public let sessionID: String
  /// The split; `nil` shows the unsplit view.
  public private(set) var state: TerminalSplitState?
  /// The shell pane whose Close Pane waits for "Close shell?".
  public var closingShell: String?

  @ObservationIgnored private let defaults: UserDefaults
  /// Shells seen in the list since it was last empty: one that leaves the list is gone.
  @ObservationIgnored private var seenShells: Set<String> = []

  /// The `UserDefaults` key prefix; the session id follows it.
  static let keyPrefix = "omnigent:terminal-split:"

  /// The session's split as this device left it.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - defaults: Where it is kept.
  public init(sessionID: String, defaults: UserDefaults = .standard) {
    self.sessionID = sessionID
    self.defaults = defaults
    state = Self.restore(defaults.data(forKey: Self.keyPrefix + sessionID))
  }

  /// A malformed or invalid saved split restores as unsplit, as on the web.
  private static func restore(_ data: Data?) -> TerminalSplitState? {
    guard let data else { return nil }
    do {
      let saved = try JSONDecoder().decode(TerminalSplitState.self, from: data)
      return TerminalSplitState(layout: saved.layout, focused: saved.focused)
    } catch {
      logger.error(
        "A saved terminal split did not decode: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  private static let logger = Logger(subsystem: "ai.omnigent.app", category: "terminal-split")

  /// Splits the focused pane with a new shell, which takes the focus.
  public func split(with shellID: String, axis: TerminalSplitAxis) {
    update(TerminalSplitState.splitting(state, with: shellID, axis: axis))
  }

  /// Drops a pane; its sibling takes the space.
  public func remove(_ key: TerminalPaneKey) {
    update(state?.removing(key))
  }

  /// Resizes the split at `path`.
  public func resize(at path: [Int], to ratio: Double) {
    update(state?.resizing(at: path, to: ratio))
  }

  /// Focuses a pane, as clicking into it does.
  public func focus(_ key: TerminalPaneKey) {
    update(state?.focusing(key))
  }

  /// Focuses the next pane (`step` 1) or the previous one (-1), wrapping.
  public func cycle(by step: Int) {
    update(state?.cycling(by: step))
  }

  /// Follows the session's terminal list: a shell pane whose terminal was in an earlier list
  /// and has left it is dropped. One never seen waits, as an emptied list refills a terminal at
  /// a time.
  /// - Parameter listedTerminalIDs: Every terminal the list holds now, the agent's included.
  public func follow(listedTerminalIDs: Set<String>) {
    if listedTerminalIDs.isEmpty {
      seenShells = []
      return
    }
    let seen = seenShells
    update(state?.reconciled(liveShellIDs: listedTerminalIDs) { seen.contains($0) })
    seenShells.formUnion(listedTerminalIDs)
  }

  /// Drops the shell panes an authoritative read of the list doesn't hold.
  /// - Parameter terminalIDs: Every terminal the session has.
  public func prune(keeping terminalIDs: Set<String>) {
    update(state?.reconciled(liveShellIDs: terminalIDs) { _ in true })
    seenShells.formUnion(terminalIDs)
  }

  private func update(_ next: TerminalSplitState?) {
    guard next != state else { return }
    state = next
    let key = Self.keyPrefix + sessionID
    guard let next else {
      defaults.removeObject(forKey: key)
      return
    }
    do {
      defaults.set(try JSONEncoder().encode(next), forKey: key)
    } catch {
      // The split lasts until the app quits; the last saved one stays.
      Self.logger.error(
        "Could not save a terminal split: \(String(describing: error), privacy: .public)")
    }
  }
}

/// Every session's ``TerminalSplitPanes``, one per session for the app's lifetime, so a
/// window's toolbar and its chat share a session's split.
public final class TerminalSplitRegistry {
  /// The app's.
  public static let shared = TerminalSplitRegistry()

  private var panes: [String: TerminalSplitPanes] = [:]
  /// Where the splits are kept, and the remembered shell (``PreferredTerminal``).
  public let defaults: UserDefaults

  /// A registry over `defaults`.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The session's split.
  public func panes(of sessionID: String) -> TerminalSplitPanes {
    if let existing = panes[sessionID] { return existing }
    let created = TerminalSplitPanes(sessionID: sessionID, defaults: defaults)
    panes[sessionID] = created
    return created
  }
}
