#if os(macOS)
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// One panel's choice, as a session keeps it.
  @MainActor
  private final class PanelChoice {
    var isShown: Bool
    var writes = 0

    init(_ isShown: Bool) { self.isShown = isShown }

    var binding: Binding<Bool> {
      Binding(
        get: { self.isShown },
        set: {
          self.writes += 1
          self.isShown = $0
        })
    }
  }

  @Suite("Inspector: the Mac column's reports")
  @MainActor
  struct InspectorColumnRelayTests {
    @Test("The end of an expand begun for one panel, reported after another's, reaches neither")
    func lateReportAfterASwitch() async {
      let relay = InspectorColumnRelay()
      let (left, next) = (PanelChoice(false), PanelChoice(false))
      relay.hand(left.binding)
      left.isShown = true
      relay.hand(left.binding)
      relay.hand(next.binding)
      #expect(!relay.isPresented, "the column is handed the next panel's choice")
      // SwiftUI writes back what the column showed when its expand ends.
      relay.isPresented = true
      #expect(!next.isShown && next.writes == 0, "the next panel chose nothing")
      #expect(left.isShown && left.writes == 0, "the panel left is as it was")
      #expect(relay.isPresented, "SwiftUI is shown where the column is, for one update")
      relay.hand(next.binding)
      let moved = await MainLoop.waitUntil(timeout: .seconds(5)) { !relay.isPresented }
      #expect(moved, "then handed the next panel's choice again, to move the column to")
      relay.isPresented = false
      #expect(next.writes == 0, "the column closing for it chooses nothing either")
    }

    @Test("A late report of a panel toggled again leaves the newer choice")
    func lateReportAfterAToggle() {
      let relay = InspectorColumnRelay()
      let panel = PanelChoice(true)
      relay.hand(panel.binding)
      panel.isShown = false
      relay.hand(panel.binding)
      panel.isShown = true
      relay.hand(panel.binding)
      relay.isPresented = false
      #expect(panel.isShown && panel.writes == 0, "the collapse ending is not a choice")
    }

    @Test("Once the column shows what it was handed, dragging it shut is the latest panel's choice")
    func settledChange() {
      let relay = InspectorColumnRelay()
      let (first, next) = (PanelChoice(true), PanelChoice(false))
      relay.hand(first.binding)
      relay.isPresented = false
      #expect(!first.isShown && first.writes == 1, "made open, it is shut by hand")
      first.isShown = true
      relay.hand(first.binding)
      relay.hand(next.binding)
      relay.isPresented = false
      next.isShown = true
      relay.hand(next.binding)
      relay.isPresented = true
      #expect(next.writes == 0, "what it was handed ends as no choice")
      relay.isPresented = false
      #expect(!next.isShown && next.writes == 1, "the panel shown chose to shut it")
      #expect(first.isShown && first.writes == 1, "not the one the column was made with")
    }
  }
#endif
