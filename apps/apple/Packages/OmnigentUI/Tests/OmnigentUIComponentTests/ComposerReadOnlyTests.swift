#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A session that takes no messages (read-only, archived, closed): its editor takes no typing.
  @Suite("Composer: a session that takes no messages", .serialized)
  @MainActor
  struct ComposerReadOnlyTests {
    private let log = ComposerActionLog()

    private var readOnly: ComposerViewState {
      var state = ComposerSamples.idle
      state.availability = .unavailable(reason: "You can read this session but not send to it.")
      return state
    }

    @Test("a composer that opens read-only takes no typing")
    func opensReadOnly() throws {
      let model = ComposerScreenModel(state: readOnly)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.type("locked")
      #expect(model.draft.isEmpty)
      #expect(log.events.isEmpty)
    }

    @Test("a composer that turns read-only while it has the keyboard stops taking typing")
    func turnsReadOnly() throws {
      let model = ComposerScreenModel(state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.type("a")
      #expect(model.draft == "a")

      model.state = readOnly
      screen.settle()
      try screen.type("b")
      #expect(model.draft == "a")
      // A click on the editor does not give it the keyboard back.
      screen.focusEditor()
      try screen.type("c")
      #expect(model.draft == "a")
    }

    @Test("a composer that becomes available again takes typing")
    func turnsEditable() throws {
      let model = ComposerScreenModel(state: readOnly)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      model.state = ComposerSamples.idle
      screen.settle()
      screen.focusEditor()
      try screen.type("a")
      #expect(model.draft == "a")
    }
  }
#endif
