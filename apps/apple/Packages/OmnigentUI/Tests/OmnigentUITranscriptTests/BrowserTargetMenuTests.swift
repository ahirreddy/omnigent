import Testing

@testable import OmnigentUIComponents

/// The browser choice the Mac toolbar's chip and the iOS title menu offer.
@Suite("Browser target menu")
struct BrowserTargetMenuTests {
  @Test("The menu lists This Mac, the agent's machine, then Auto, each with its symbol")
  func choices() {
    #expect(BrowserTargetChoice.menuOrder == [.local, .remote, .auto])
    #expect(
      BrowserTargetChoice.menuOrder.map(\.title) == ["This Mac", "Agent\u{2019}s machine", "Auto"])
    #expect(
      BrowserTargetChoice.menuOrder.map(\.systemImage)
        == ["laptopcomputer", "cloud", "wand.and.stars"])
  }

  @Test("This Mac is off with a reason for a shared session; the other two stay on")
  func sharedSession() {
    let open = BrowserTargetState(choice: .auto)
    #expect(BrowserTargetChoice.allCases.allSatisfy(open.allows))
    let shared = BrowserTargetState(
      choice: .remote, localUnavailableReason: BrowserTargetState.ownerOnly)
    #expect(!shared.allows(.local))
    #expect(shared.allows(.remote) && shared.allows(.auto))
    #expect(shared.summary == "Browser: Agent\u{2019}s machine")
  }

  #if os(macOS)
    @Test("The chip takes titlebar room beside the other trailing items")
    func titlebarWidth() {
      var state = ConversationViewState(header: SessionHeader(id: "s", title: "T"))
      let without = TitlebarTrailingItems.count(
        state, hasShare: false, tabsInTitlebar: true, isRegular: true)
      state.browserTarget = BrowserTargetState(choice: .local)
      #expect(
        TitlebarTrailingItems.count(state, hasShare: false, tabsInTitlebar: true, isRegular: true)
          == without + BrowserTargetChip.width(.local))
      #expect(BrowserTargetChip.width(.remote) > BrowserTargetChip.width(.auto))
    }
  #endif
}
