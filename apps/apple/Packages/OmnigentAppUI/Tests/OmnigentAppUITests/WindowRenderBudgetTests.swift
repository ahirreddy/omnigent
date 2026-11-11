import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentUIComponents

#if DEBUG
  /// What an interaction may count beside the renders of the pass that applies it.
  nonisolated enum CountLimit: Sendable {
    /// Not counted.
    case unchecked
    /// The most each name may count. A name that is not listed may not count at all.
    case atMost([String: Int])
  }

  /// One thing the user or the server does to the mounted window, with what it may render.
  nonisolated struct WindowInteraction: CustomTestStringConvertible, Sendable {
    typealias Step = @MainActor @Sendable (BudgetWindow) throws -> Void

    let name: String
    /// The most each scope may render, by the name it counts renders under. A scope that is not
    /// listed may not render at all, so a new scope starts at none.
    let budget: [String: Int]
    /// The app's own layouts in the same pass, by the name ``LayoutTally`` counts them under.
    var layouts = CountLimit.unchecked
    /// Renders and layouts after that pass until the window is quiet: what its tasks start.
    var later = CountLimit.unchecked
    /// Brings the window to where the interaction starts, outside the count.
    var prepare: @MainActor @Sendable (BudgetWindow) async throws -> Void = { _ in }
    /// Does it, the way the server's event or the user's input reaches the window.
    let perform: Step
    /// Puts back what it changed outside the window, before any other test can run.
    var afterwards: Step = { _ in }
    /// Reads what it changed from what the window draws.
    let verify: @MainActor @Sendable (BudgetWindow) async throws -> Void

    var testDescription: String { name }
  }

  /// What each interaction may render in the mounted window, and proof that what it changed is
  /// drawn. A broad read put back at a root renders a scope its interaction does not allow; a
  /// read narrowed too far leaves the old value on screen.
  @MainActor
  @Suite("Window render budgets", .serialized, .timeLimit(.minutes(1)))
  struct WindowRenderBudgetTests {
    @Test("An interaction renders only the scopes that show it", arguments: WindowInteraction.all)
    func staysWithinItsBudget(_ interaction: WindowInteraction) async throws {
      let window = try await BudgetWindow.open()
      defer { window.screen.close() }
      try await interaction.prepare(window)
      try await window.settleUntilQuiet()
      var failure: (any Error)?
      var renders: [String: Int] = [:]
      let layouts = LayoutTally.recording {
        renders = RenderTally.recording {
          do {
            try interaction.perform(window)
          } catch let error {
            failure = error
          }
          window.screen.settle(0.3)
        }
      }
      try interaction.afterwards(window)
      if let failure { throw failure }
      Self.hold(renders, to: .atMost(interaction.budget), counting: "renders")
      Self.hold(layouts, to: interaction.layouts, counting: "layouts")
      let later = try await window.settleUntilQuiet()
      Self.hold(later, to: interaction.later, counting: "renders and layouts afterwards")
      try await interaction.verify(window)
    }

    /// Records a failure for each name that counted more than `limit` allows.
    private static func hold(_ counts: [String: Int], to limit: CountLimit, counting: String) {
      guard case .atMost(let budget) = limit else { return }
      let over = counts.filter { $0.value > budget[$0.key, default: 0] }
      guard !over.isEmpty else { return }
      Issue.record(
        BudgetFailure.overBudget(over, counted: counts, budget: budget, counting: counting))
    }

    @Test("A window that keeps rendering fails the wait for it, naming what rendered")
    func neverQuietIsNamed() async throws {
      let window = try await BudgetWindow.open()
      defer { window.screen.close() }
      // A size change renders the strip in the run loop pass that takes it, on any machine.
      var isNarrow = false
      let resizing = Timer(timeInterval: 0.02, repeats: true) { _ in
        MainActor.assumeIsolated {
          isNarrow.toggle()
          window.screen.window.setContentSize(CGSize(width: isNarrow ? 860 : 900, height: 600))
        }
      }
      RunLoop.main.add(resizing, forMode: .common)
      defer { resizing.invalidate() }
      await #expect {
        try await window.settleUntilQuiet(timeout: .seconds(1))
      } throws: { error in
        guard case BudgetFailure.neverQuiet(let rendered) = error else { return false }
        return rendered["strip", default: 0] > 1
      }
      resizing.invalidate()
      try await window.settleUntilQuiet()
    }

    @Test("Every interaction has a name of its own")
    func namesAreDistinct() {
      let names = WindowInteraction.all.map(\.name)
      #expect(Set(names).count == names.count, "\(names)")
    }
  }
#endif
