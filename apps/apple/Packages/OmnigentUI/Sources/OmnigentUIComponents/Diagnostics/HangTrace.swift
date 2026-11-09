#if DEBUG
  import Foundation
  private import os

  /// What layout did lately, readable from another thread when the main thread stops returning
  /// to its run loop: the latest ``LoopProbe`` changes and a count of layout passes per name, so
  /// a hang can be told apart as one slow pass or many identical ones. Debug builds only; nothing
  /// is kept until a host sets ``isEnabled``.
  public nonisolated enum HangTrace {
    /// How many changes ``report(since:)`` lists.
    static let keptChanges = 30
    /// How many names ``report(since:)`` lists.
    static let reportedPasses = 12

    private struct State {
      var isEnabled = false
      var changes: [String] = []
      var passes: [String: Int] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Whether changes and passes are kept.
    public static var isEnabled: Bool {
      get { state.withLock { $0.isEnabled } }
      set { state.withLock { $0.isEnabled = newValue } }
    }

    /// Keeps the latest change of a probed value.
    static func change(_ line: @autoclosure () -> String) {
      guard isEnabled else { return }
      let line = line()
      state.withLock {
        $0.changes.append(line)
        if $0.changes.count > keptChanges * 2 { $0.changes.removeFirst(keptChanges) }
      }
    }

    /// Counts one layout pass over `name`.
    static func pass(_ name: @autoclosure () -> String) {
      guard isEnabled else { return }
      let name = name()
      state.withLock { $0.passes[name, default: 0] += 1 }
    }

    /// The pass counts so far, to compare a later report against.
    public static func passCounts() -> [String: Int] {
      state.withLock { $0.passes }
    }

    /// The names with the most passes since `earlier`, and the latest changes.
    public static func report(since earlier: [String: Int]) -> String {
      let current = state.withLock { $0 }
      let grown = current.passes.compactMap { name, count -> (name: String, count: Int)? in
        let added = count - (earlier[name] ?? 0)
        return added > 0 ? (name, added) : nil
      }
      let top = grown.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        .prefix(reportedPasses).map { "\($0.name) +\($0.count)" }
      return "passes: \(top.isEmpty ? "none" : top.joined(separator: ", "))\n"
        + "changes: \(current.changes.suffix(keptChanges).joined(separator: " | "))"
    }

    /// Forgets everything, for tests.
    static func reset() {
      state.withLock { $0 = State() }
    }
  }
#endif
