import Foundation
private import os

/// What layout did lately, readable from another thread when the main thread stops returning
/// to its run loop. Every build counts the changes of each probed value, so a stall can name
/// what kept changing. Debug builds also keep the latest ``LoopProbe`` changes and a count of
/// layout passes per name once a host sets ``isEnabled``.
public nonisolated enum HangTrace {
  /// How many changes ``report(since:)`` lists.
  static let keptChanges = 30
  /// How many names ``report(since:)`` and ``busiest(since:)`` list.
  static let reportedPasses = 12
  /// How many probed values are counted before the counts start again.
  static let keptSources = 512

  /// One probed value of one view.
  struct Source: Hashable, Sendable {
    var name: String
    /// Tells apart views probing the same value; 0 for a value there is one of.
    var tag = 0

    var label: String { tag == 0 ? name : "\(name) \(tag)" }
  }

  /// How often each probed value had changed at one moment.
  public struct Tallies: Sendable {
    fileprivate var counts: [Source: Int] = [:]
    /// How many times the counts have started again.
    fileprivate var restarts = 0

    /// How often the value called `name` changed since `earlier`, over every view probing it.
    func count(_ name: String, since earlier: Self) -> Int {
      added(since: earlier).reduce(0) { $1.key.name == name ? $0 + $1.value : $0 }
    }

    /// What each count grew by since `earlier`; all of it when the counts started again since.
    fileprivate func added(since earlier: Self) -> [Source: Int] {
      guard earlier.restarts == restarts else { return counts }
      var added = counts
      for (source, count) in counts { added[source] = count - (earlier.counts[source] ?? 0) }
      return added
    }
  }

  private struct State {
    var isEnabled = false
    var changes: [String] = []
    var passes: [String: Int] = [:]
    var tallies = Tallies()
  }

  private static let state = OSAllocatedUnfairLock(initialState: State())

  /// Whether changes and passes are kept.
  public static var isEnabled: Bool {
    get { state.withLock { $0.isEnabled } }
    set { state.withLock { $0.isEnabled = newValue } }
  }

  /// Counts one change of a probed value. Builds no string, so it is always on.
  static func tally(_ source: Source) {
    state.withLock {
      if $0.tallies.counts.count >= keptSources, $0.tallies.counts[source] == nil {
        $0.tallies.counts.removeAll(keepingCapacity: true)
        $0.tallies.restarts += 1
      }
      $0.tallies.counts[source, default: 0] += 1
    }
  }

  /// The change counts so far, to compare a later moment against.
  public static func tallies() -> Tallies {
    state.withLock { $0.tallies }
  }

  /// The probed values that changed most since `earlier`, most first; "nothing probed" when
  /// none did.
  public static func busiest(since earlier: Tallies) -> String {
    let grown: [(name: String, count: Int)] = tallies().added(since: earlier).compactMap {
      $0.value > 0 ? ($0.key.label, $0.value) : nil
    }
    return grown.isEmpty ? "nothing probed" : top(grown)
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
    return "passes: \(grown.isEmpty ? "none" : top(grown))\n"
      + "changes: \(current.changes.suffix(keptChanges).joined(separator: " | "))"
  }

  /// The largest counts, most first.
  private static func top(_ counts: [(name: String, count: Int)]) -> String {
    counts.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
      .prefix(reportedPasses).map { "\($0.name) +\($0.count)" }.joined(separator: ", ")
  }

  /// Forgets everything, for tests. The counts start again, as they do when full.
  static func reset() {
    state.withLock { $0 = State(tallies: Tallies(restarts: $0.tallies.restarts + 1)) }
  }
}
