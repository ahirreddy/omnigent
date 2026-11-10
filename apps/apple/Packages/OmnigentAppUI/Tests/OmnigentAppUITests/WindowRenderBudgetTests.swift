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
  /// One thing the user or the server does to the mounted window, with what it may render.
  nonisolated struct WindowInteraction: CustomTestStringConvertible, Sendable {
    typealias Step = @MainActor @Sendable (BudgetWindow) throws -> Void

    let name: String
    /// The most each scope may render, by the name it counts renders under. A scope that is not
    /// listed may not render at all, so a new scope starts at none.
    let budget: [String: Int]
    /// Brings the window to where the interaction starts, outside the count.
    var prepare: Step = { _ in }
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
      try interaction.prepare(window)
      try await pause(window.screen, .milliseconds(300))
      var failure: (any Error)?
      let renders = RenderTally.recording {
        do {
          try interaction.perform(window)
        } catch let error {
          failure = error
        }
        window.screen.settle(0.3)
      }
      try interaction.afterwards(window)
      if let failure { throw failure }
      let over = renders.filter { $0.value > interaction.budget[$0.key, default: 0] }
      #expect(over.isEmpty, "over budget: \(over.sorted { $0.key < $1.key }) of \(renders)")
      try await pause(window.screen, .milliseconds(200))
      try await interaction.verify(window)
    }

    @Test("Every interaction has a name of its own")
    func namesAreDistinct() {
      let names = WindowInteraction.all.map(\.name)
      #expect(Set(names).count == names.count, "\(names)")
    }
  }
#endif
