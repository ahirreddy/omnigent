import Foundation
import Synchronization

/// Lays message texts out off the main actor, in the order they are wanted: those asked for
/// ahead (``prioritize(_:at:)``) nearest the reader first, on a few workers at once, then those
/// offered, newest first, on one, so work far from the reader doesn't crowd the main thread. What laying a text out means and the context it is laid out in (a
/// style, a width, a scale) are the platform's: the Mac's ``MessageTextPrewarm`` builds TextKit
/// documents and draws the texts asked for ahead.
nonisolated final class MessageTextPrewarmQueue<Context: Sendable>: Sendable {
  /// A text asked for ahead, where it is in the list.
  private struct Wanted {
    var text: String
    var position: Double
  }

  private struct State {
    var context: Context?
    /// Texts offered, newest first, to lay out again when the context changes.
    var offered: [String] = []
    /// Offered texts waiting, first to last.
    var pending: [String] = []
    /// Texts asked for ahead, waiting.
    var wanted: [Wanted] = []
    /// Texts being laid out now.
    var running: Set<String> = []
    /// Texts laid out in this context, and whether they were asked for ahead.
    var done: [String: Bool] = [:]
    /// Where the reader is, and which way they move: +1 down the list, -1 up it, 0 still.
    var focus: Double = 0
    var direction = 0
    var workers = 0
    /// Workers laying out an offered text: one at most.
    var offeredWorkers = 0
    /// Raised with each new context, so a text laid out in an old one isn't counted done.
    var generation = 0
  }

  /// One text for a worker: whether it was asked for ahead, and the context it lays out in.
  private struct Work {
    var text: String
    var wanted: Bool
    var context: Context
    var generation: Int
  }

  private let limit: Int
  private let workerLimit: Int
  private let state: Mutex<State>
  private let prepare: @Sendable (String, _ wanted: Bool, Context) -> Void

  /// - Parameters:
  ///   - limit: How many texts it remembers and queues.
  ///   - workers: How many texts lay out at once.
  ///   - prepare: Lays one text out in a context, off the main actor; `wanted` says it was
  ///     asked for ahead.
  init(
    limit: Int, workers: Int = 1,
    prepare: @escaping @Sendable (String, _ wanted: Bool, Context) -> Void
  ) {
    self.limit = limit
    workerLimit = max(1, workers)
    self.prepare = prepare
    state = Mutex(State())
  }

  /// The context texts lay out in, once one is set.
  var context: Context? { state.withLock { $0.context } }

  /// The texts waiting to lay out, in the order they would go now.
  var pendingTexts: [String] {
    state.withLock { state in
      Self.ordered(state.wanted, focus: state.focus, direction: state.direction).map(\.text)
        + state.pending
    }
  }

  /// Sets the context, unless `isSame` says the current one already is it; a new context lays
  /// out every text offered so far again.
  func setContext(_ context: Context, isSame: (Context) -> Bool) {
    let start = state.withLock { state -> Int in
      if let current = state.context, isSame(current) { return 0 }
      state.context = context
      state.pending = state.offered
      state.done = [:]
      state.generation += 1
      return claimWorkers(&state)
    }
    run(start)
  }

  /// Queues a text, behind those already waiting, unless it is laid out.
  func offer(_ text: String) {
    let start = state.withLock { state -> Int in
      if state.offered.count < limit { state.offered.append(text) }
      guard state.context != nil, state.done[text] == nil, state.pending.count < limit else {
        return 0
      }
      state.pending.append(text)
      return claimWorkers(&state)
    }
    run(start)
  }

  /// Asks for `texts` ahead of the offered ones, at their `positions` in the list (points from
  /// its top, say): the one nearest the reader goes first. A text asked for again moves.
  func prioritize(_ texts: [String], at positions: [Double]) {
    guard !texts.isEmpty else { return }
    let start = state.withLock { state -> Int in
      for (text, position) in zip(texts, positions) {
        guard state.done[text] != true, !state.running.contains(text) else { continue }
        if let index = state.wanted.firstIndex(where: { $0.text == text }) {
          state.wanted[index].position = position
        } else {
          state.wanted.append(Wanted(text: text, position: position))
        }
      }
      // The oldest asks go first: the reader has moved on from them. Asks outlast a new
      // context.
      if state.wanted.count > limit { state.wanted.removeFirst(state.wanted.count - limit) }
      guard state.context != nil else { return 0 }
      return claimWorkers(&state)
    }
    run(start)
  }

  /// Puts `texts` ahead of the rest, the first nearest.
  func prioritize(_ texts: [String]) {
    let base = state.withLock { $0.focus }
    prioritize(texts, at: texts.indices.map { base + Double($0) })
  }

  /// Where the reader is in the list and which way they move: texts asked for ahead of them in
  /// that direction go before those behind.
  func focus(at position: Double, direction: Int) {
    state.withLock { state in
      state.focus = position
      state.direction = direction
    }
  }

  /// `wanted` nearest `focus` first; those behind a moving reader count three times as far.
  private static func ordered(_ wanted: [Wanted], focus: Double, direction: Int) -> [Wanted] {
    wanted.sorted { distance($0, focus, direction) < distance($1, focus, direction) }
  }

  private static func distance(_ wanted: Wanted, _ focus: Double, _ direction: Int) -> Double {
    let offset = (wanted.position - focus) * Double(direction == 0 ? 1 : direction)
    return direction == 0 ? abs(offset) : (offset >= 0 ? offset : -offset * 3)
  }

  /// How many more workers this caller starts: one per text asked for ahead, and one for the
  /// offered texts, up to the limit.
  private func claimWorkers(_ state: inout State) -> Int {
    let offered = !state.pending.isEmpty && state.offeredWorkers == 0 ? 1 : 0
    let start = min(workerLimit - state.workers, state.wanted.count + offered)
    guard start > 0 else { return 0 }
    state.workers += start
    return start
  }

  private func run(_ workers: Int) {
    for _ in 0..<workers {
      Task.detached(priority: .utility) { [self] in
        while let work = next() {
          prepare(work.text, work.wanted, work.context)
          finish(work.text, wanted: work.wanted, generation: work.generation)
        }
      }
    }
  }

  /// The next text to lay out, whether it was asked for ahead, and its context; `nil` ends the
  /// worker.
  private func next() -> Work? {
    state.withLock { state in
      guard let context = state.context else {
        state.workers -= 1
        return nil
      }
      if !state.wanted.isEmpty {
        let focus = state.focus
        let direction = state.direction
        var best = 0
        for index in state.wanted.indices.dropFirst()
        where Self.distance(state.wanted[index], focus, direction)
          < Self.distance(state.wanted[best], focus, direction)
        {
          best = index
        }
        let text = state.wanted.remove(at: best).text
        state.running.insert(text)
        return Work(text: text, wanted: true, context: context, generation: state.generation)
      }
      while state.offeredWorkers == 0, !state.pending.isEmpty {
        let text = state.pending.removeFirst()
        guard state.done[text] == nil, !state.running.contains(text) else { continue }
        state.running.insert(text)
        state.offeredWorkers += 1
        return Work(text: text, wanted: false, context: context, generation: state.generation)
      }
      state.workers -= 1
      return nil
    }
  }

  /// Records `text` as laid out, drawn too when it was asked for ahead.
  private func finish(_ text: String, wanted: Bool, generation: Int) {
    state.withLock { state in
      state.running.remove(text)
      if !wanted { state.offeredWorkers -= 1 }
      guard generation == state.generation else { return }
      if state.done.count >= limit * 4 { state.done = [:] }
      state.done[text] = wanted || state.done[text] == true
    }
  }
}
