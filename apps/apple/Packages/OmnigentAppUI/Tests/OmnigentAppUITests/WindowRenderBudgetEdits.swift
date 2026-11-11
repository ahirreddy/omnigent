import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

#if DEBUG
  nonisolated extension WindowInteraction {
    /// The user's own edits of the list, shown before the server answers them.
    static let edits: [WindowInteraction] = [
      WindowInteraction(
        name: "a rename the server has not answered",
        // The edit starts in a task, so the pass of the click itself draws nothing.
        budget: [:],
        later: .atMost(["session row": 1]),
        prepare: { window in
          let path = "/v1/sessions/\(BudgetWindow.other)"
          window.notes.gate = window.server.hold(path, method: "PATCH")
          let renamed = try #require(window.list.session(BudgetWindow.other))
          let row = sessionRow(
            renamed.id, host: "mac", workspace: "/work/\(renamed.id)",
            updatedAt: renamed.updatedAt)
          window.server.route(
            path, method: "PATCH", .json(#"{"title":"Gamma edited","# + row.dropFirst()))
        },
        perform: { window in
          window.notes.edit = Task {
            await window.list.rename(BudgetWindow.other, to: "Gamma edited")
          }
        },
        verify: { window in
          let held = try window.screen.shownText()
          #expect(held.contains("Gamma edited"), "the row shows it before the answer: \(held)")
          #expect(window.notes.gate?.arrivals == 1, "the write is still at the server")
          window.notes.gate?.release()
          let answered = try await window.settleUntilQuiet()
          #expect(await window.notes.edit?.value == true)
          #expect(answered["session row", default: 0] <= 1, "the answer: \(answered)")
          #expect(window.list.editError == nil)
          let text = try window.screen.shownText()
          #expect(text.contains("Gamma edited") && !text.contains("Gamma"), "\(text)")
        })
    ]
  }
#endif
