import OmnigentUIComponents
import SwiftUI
import Testing

@testable import OmnigentAppUI

@MainActor
struct ConversationModeRouteTests {
  @Test func withoutTabsTheModeIsStored() {
    let route = ConversationModeRoute()
    #expect(route.mode == .chat)
    route.mode = .terminal
    #expect(route.mode == .terminal)
    route.mode = .chat
    #expect(route.mode == .chat)
  }

  @Test func withTabsTerminalOpensTheHarnessAndStaysOnChat() {
    let route = ConversationModeRoute()
    var opened = 0
    route.openHarness = { opened += 1 }
    route.mode = .terminal
    #expect(opened == 1)
    #expect(route.mode == .chat)
    route.mode = .chat
    #expect(opened == 1)
  }

  @Test func modeBindingSetsTheHarnessOpener() {
    let route = ConversationModeRoute()
    var opened = 0
    let binding = route.mode({ opened += 1 }, .constant(route))
    binding.wrappedValue = .terminal
    #expect(opened == 1)
    #expect(binding.wrappedValue == .chat)
  }

  @Test func forkSheetBindingCancelsOnlyOnDismiss() {
    let flow = ForkFlow()
    #expect(flow.sheet == nil)
    // Dismissing with nothing shown writes no state.
    flow.sheet = nil
    #expect(flow.sheet == nil)
  }
}
