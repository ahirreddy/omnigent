import Foundation
import Synchronization

/// Lays message texts out off the main actor, one at a time, in the order they are wanted:
/// newest first as they are offered, and those about to scroll into view (``prioritize(_:)``)
/// ahead of the rest. What laying a text out means and the context it is laid out in (a style,
/// a width, a scale) are the platform's: the Mac's ``MessageTextPrewarm`` builds TextKit
/// documents and draws them ahead.
nonisolated final class MessageTextPrewarmQueue<Context: Sendable>: Sendable {
  private struct State {
    var context: Context?
    /// Texts offered, newest first, to lay out again when the context changes.
    var offered: [String] = []
    var pending: [String] = []
    var isRunning = false
  }

  private let limit: Int
  private let state: Mutex<State>
  private let prepare: @Sendable (String, Context) -> Void

  /// - Parameters:
  ///   - limit: How many texts it remembers and queues.
  ///   - prepare: Lays one text out in a context, off the main actor.
  init(limit: Int, prepare: @escaping @Sendable (String, Context) -> Void) {
    self.limit = limit
    self.prepare = prepare
    state = Mutex(State())
  }

  /// The context texts lay out in, once one is set.
  var context: Context? { state.withLock { $0.context } }

  /// The texts waiting to lay out, first to last.
  var pendingTexts: [String] { state.withLock { $0.pending } }

  /// Sets the context, unless `isSame` says the current one already is it; a new context lays
  /// out every text offered so far again.
  func setContext(_ context: Context, isSame: (Context) -> Bool) {
    let start = state.withLock { state -> Bool in
      if let current = state.context, isSame(current) { return false }
      state.context = context
      state.pending = state.offered
      return Self.claimRun(&state)
    }
    if start { run() }
  }

  /// Queues a text, behind those already waiting.
  func offer(_ text: String) {
    let start = state.withLock { state -> Bool in
      if state.offered.count < limit { state.offered.append(text) }
      guard state.context != nil, state.pending.count < limit else { return false }
      state.pending.append(text)
      return Self.claimRun(&state)
    }
    if start { run() }
  }

  /// Puts `texts` at the front of the queue, in order, once each.
  func prioritize(_ texts: [String]) {
    guard !texts.isEmpty else { return }
    let start = state.withLock { state -> Bool in
      let wanted = Set(texts)
      // First among the offers too, so a new context lays them out first again.
      state.pending = Self.front(texts, of: state.pending, wanted: wanted, limit: limit)
      state.offered = Self.front(texts, of: state.offered, wanted: wanted, limit: limit)
      guard state.context != nil else { return false }
      return Self.claimRun(&state)
    }
    if start { run() }
  }

  private static func front(
    _ texts: [String], of list: [String], wanted: Set<String>, limit: Int
  ) -> [String] {
    Array((texts + list.filter { !wanted.contains($0) }).prefix(limit))
  }

  /// Whether this caller starts the run: nothing runs yet and there is work.
  private static func claimRun(_ state: inout State) -> Bool {
    guard !state.isRunning, !state.pending.isEmpty else { return false }
    state.isRunning = true
    return true
  }

  private func run() {
    Task.detached(priority: .utility) { [self] in
      while let work = next() {
        prepare(work.text, work.context)
      }
    }
  }

  /// The next text to lay out and its context; `nil` ends the run.
  private func next() -> (text: String, context: Context)? {
    state.withLock { state in
      guard let context = state.context, !state.pending.isEmpty else {
        state.isRunning = false
        return nil
      }
      return (state.pending.removeFirst(), context)
    }
  }
}
