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

  @Test func withTabsTheWindowKeepsTheMode() {
    let groups = SessionTabGroups()
    let route = ConversationModeRoute()
    route.remembered = groups.viewChoice("s")
    #expect(route.mode == .chat)
    route.mode = .terminal
    #expect(route.mode == .terminal)
    #expect(groups.viewMode("s") == .terminal)
    #expect(groups.viewMode("other") == .chat)

    // Another view of the same chat (rebuilt after its tab was let go) shows the same mode.
    let rebuilt = ConversationModeRoute()
    rebuilt.remembered = groups.viewChoice("s")
    #expect(rebuilt.mode == .terminal)
    rebuilt.mode = .chat
    #expect(route.mode == .chat)
  }

  @Test func modeBindingUsesTheWindowsChoice() {
    let groups = SessionTabGroups()
    let route = ConversationModeRoute()
    let binding = route.mode(groups.viewChoice("s"), .constant(route))
    binding.wrappedValue = .terminal
    #expect(binding.wrappedValue == .terminal)
    #expect(groups.viewMode("s") == .terminal)

    // Without tabs the route keeps the mode itself.
    let alone = ConversationModeRoute()
    let own = alone.mode(nil, .constant(alone))
    own.wrappedValue = .terminal
    #expect(own.wrappedValue == .terminal)
  }

  @Test func panelFollowsTheDefaultUntilTheChatChooses() {
    let route = ConversationPanelRoute()
    let shown = route.isShown(default: .open, isSheet: false, .constant(route))
    #expect(shown.wrappedValue)
    // A sheet (compact width) starts closed.
    #expect(!route.isShown(default: .open, isSheet: true, .constant(route)).wrappedValue)
    route.isShown = true
    #expect(route.choice == .open)
    #expect(route.isShown(default: .collapsed, isSheet: true, .constant(route)).wrappedValue)
    route.isShown = false
    #expect(route.choice == .collapsed)
    #expect(!route.isShown(default: .open, isSheet: false, .constant(route)).wrappedValue)
  }

  @Test func forkSheetBindingCancelsOnlyOnDismiss() {
    let flow = ForkFlow()
    #expect(flow.sheet == nil)
    // Dismissing with nothing shown writes no state.
    flow.sheet = nil
    #expect(flow.sheet == nil)
  }
}
