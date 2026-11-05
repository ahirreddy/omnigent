import Observation
import SwiftUI
import Synchronization
import Testing

@testable import OmnigentUIComponents

@Suite("Composer draft handed through the conversation screen")
struct ComposerDraftTests {
  @Observable
  final class Model {
    var text = ""
  }

  final class Changes: Sendable {
    let count = Mutex(0)
  }

  @Test("Making the draft reads nothing; the composer's binding reads and writes the text")
  func readsOnlyInTheComposer() {
    let model = Model()
    let changes = Changes()
    let draft = withObservationTracking {
      ComposerDraft(get: { model.text }, set: { model.text = $0 })
    } onChange: {
      changes.count.withLock { $0 += 1 }
    }
    model.text = "typed"
    #expect(
      changes.count.withLock { $0 } == 0, "a screen holding the draft does not track the text")
    let binding = draft.binding
    #expect(binding.wrappedValue == "typed")
    binding.wrappedValue = "edited"
    #expect(model.text == "edited")
  }

  @Test("Only text besides whitespace counts as something to send")
  func hasText() {
    #expect(!ComposerDraftText.hasText(""))
    #expect(!ComposerDraftText.hasText(" \n\t"))
    #expect(ComposerDraftText.hasText(" a "))
  }
}
