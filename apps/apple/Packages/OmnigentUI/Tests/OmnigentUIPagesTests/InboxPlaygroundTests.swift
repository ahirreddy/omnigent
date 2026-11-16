#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inbox sample triage", .serialized)
  @MainActor
  struct InboxPlaygroundTests {
    @Test("the sample counts sessions that need you, not requests")
    func needsYouCount() {
      let state = InboxTriageSamples.state
      #expect(state.needsYouCount == InboxTriageSamples.sessionsNeedingYou(state.items))
      #expect(state.items.contains { $0.isPinned })
    }

    @Test("Return opens the selected request in its sheet, and Back returns")
    func openAndBack() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(InboxTriagePlayground(), width: 900, height: 900)
      defer { screen.close() }
      try screen.press(keyCode: 36, characters: "\r")
      #expect(MainLoop.settle(until: { screen.window.attachedSheet != nil }))
      try screen.clickControl(at: 0)
      #expect(MainLoop.settle(until: { screen.window.attachedSheet == nil }))
    }

    @Test("E answers the selected request in place, and the session needs you until all are")
    func approveInPlace() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(InboxTriagePlayground(), width: 900, height: 900)
      defer { screen.close() }
      let items = InboxTriageSamples.state.items
      let answered = DecisionResponse.approve.summary
      #expect(try !screen.shows(answered))
      #expect(try screen.shows("\(InboxTriageSamples.sessionsNeedingYou(items)) need"))
      // The list's own order puts a question first, which E leaves for the row's own buttons.
      try screen.press(keyCode: 0, characters: "e")
      #expect(try !screen.shows(answered))
      for _ in items where try !screen.shows(answered) {
        try screen.press(keyCode: 0, characters: "j")
        try screen.press(keyCode: 0, characters: "e")
      }
      #expect(try screen.shows(answered))
    }
  }
#endif
