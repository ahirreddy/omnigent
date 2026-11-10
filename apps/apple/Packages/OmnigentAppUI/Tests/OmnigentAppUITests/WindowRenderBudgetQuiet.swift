import Foundation
import OmnigentTestSupport
import OmnigentViewTesting
import Testing

@testable import OmnigentUIComponents

#if DEBUG
  /// Why a count failed, with all a log needs to tell which scope it was.
  nonisolated enum BudgetFailure: Error, CustomStringConvertible {
    /// The window was still rendering, or asking its server, when the wait for it ended.
    case neverQuiet(rendered: [String: Int])
    /// Scopes rendered more than the interaction allows.
    case overBudget([String: Int], rendered: [String: Int], budget: [String: Int])

    var description: String {
      switch self {
      case .neverQuiet(let rendered):
        "the window never went quiet; while waiting it rendered \(Self.listed(rendered))"
      case .overBudget(let over, let rendered, let budget):
        "over budget: \(Self.listed(over)); rendered: \(Self.listed(rendered)); "
          + "budget: \(Self.listed(budget))"
      }
    }

    /// The counts by name, in the same order in every log.
    static func listed(_ counts: [String: Int]) -> String {
      let named = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
      return named.isEmpty ? "nothing" : named.joined(separator: ", ")
    }
  }

  extension BudgetWindow {
    /// How long nothing may render or reach the server before the window counts as quiet.
    static let quiet: Duration = .milliseconds(300)
    /// How many run loop passes in a row must find nothing to do as well: on a loaded machine
    /// ``quiet`` can go by between two passes, with work still on its way to the main thread.
    static let quietPasses = 20

    /// Runs the window until it has been quiet for ``quiet`` and ``quietPasses``, so what the
    /// step before started (a session's load, a kept chat's first layout) is over on any
    /// machine. It returns from a run loop pass without suspending, so a count can start at once.
    func settleUntilQuiet(timeout: Duration = .seconds(10)) async throws {
      let clock = ContinuousClock()
      let start = clock.now
      var quietSince = start
      var idlePasses = 0
      var requests = server.http.requests.count
      var stray: [String: Int] = [:]
      while clock.now - quietSince < Self.quiet || idlePasses < Self.quietPasses {
        guard clock.now - start < timeout else { throw BudgetFailure.neverQuiet(rendered: stray) }
        // Suspending runs the window's tasks and the core's events; the run loop draws them.
        await Task.yield()
        let rendered = RenderTally.recording { screen.settle(0.01) }
        let asked = server.http.requests.count
        if rendered.isEmpty, asked == requests {
          idlePasses += 1
        } else {
          quietSince = clock.now
          idlePasses = 0
          requests = asked
          stray.merge(rendered, uniquingKeysWith: +)
        }
      }
    }
  }
#endif
