import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// A focused value rebuilt on every update republished new closures each time, which on iOS
/// rebuilt the menus and updated the view again (a busy loop).
@Suite("Focused menu actions keep their identity across updates")
@MainActor
struct FocusedActionsRelayTests {
  @Test("two updates with fresh closures publish one value that calls the latest closures")
  func sessionCommandsStayPublished() throws {
    let relay = FocusedActionsRelay<SessionCommandActions>()
    var sent: [String] = []
    _ = relay.publish(SessionCommandActions(send: { sent.append("first") }))
    let published = try #require(
      relay.publish(SessionCommandActions(send: { sent.append("second") })))
    #expect(relay.publications == 1)
    published.send?()
    #expect(sent == ["second"])
  }

  @Test("a change to what the menus show publishes a new value")
  func signatureChangeRepublishes() throws {
    let relay = FocusedActionsRelay<SessionCommandActions>()
    _ = relay.publish(SessionCommandActions(send: {}))
    let stopped = try #require(relay.publish(SessionCommandActions(interrupt: {})))
    #expect(relay.publications == 2)
    #expect(stopped.send == nil)
    #expect(stopped.interrupt != nil)

    var owned = SessionCommandActions(interrupt: {})
    owned.approveOwnsCommandReturn = true
    let approving = try #require(relay.publish(owned))
    #expect(relay.publications == 3)
    #expect(approving.approveOwnsCommandReturn)
  }

  @Test("nil clears the published value")
  func nilClears() {
    let relay = FocusedActionsRelay<SessionCommandActions>()
    _ = relay.publish(SessionCommandActions(send: {}))
    #expect(relay.publish(nil) == nil)
    _ = relay.publish(SessionCommandActions(send: {}))
    #expect(relay.publications == 2)
  }

  @Test("tab commands forward every action and republish on count and split changes")
  func tabCommandsForward() throws {
    let relay = FocusedActionsRelay<TabCommandActions>()
    var calls: [String] = []
    func actions(count: Int) -> TabCommandActions {
      var actions = TabCommandActions(
        newTab: { calls.append("new") }, closeTab: { calls.append("close") },
        selectTab: { calls.append("select \($0)") }, count: count)
      actions.focusPane = { calls.append("pane \($0)") }
      return actions
    }
    _ = relay.publish(actions(count: 2))
    let published = try #require(relay.publish(actions(count: 2)))
    #expect(relay.publications == 1)
    published.newTab()
    published.closeTab?()
    published.selectTab(3)
    published.focusPane?(.trailing)
    #expect(calls == ["new", "close", "select 3", "pane trailing"])

    _ = relay.publish(actions(count: 3))
    #expect(relay.publications == 2)
  }

  @Test("palette commands keep one value across updates")
  func paletteCommandsStay() throws {
    let relay = FocusedActionsRelay<PaletteCommandActions>()
    var opened = 0
    _ = relay.publish(PaletteCommandActions(openPalette: {}, openShortcuts: {}))
    let published = try #require(
      relay.publish(PaletteCommandActions(openPalette: { opened += 1 }, openShortcuts: {})))
    #expect(relay.publications == 1)
    published.openPalette()
    #expect(opened == 1)
  }

  @Test("server commands forward to the latest and republish when Sign Out appears")
  func serverCommandsForward() throws {
    let relay = FocusedActionsRelay<ServerCommandActions>()
    var calls: [String] = []
    _ = relay.publish(ServerCommandActions(reconnect: { calls.append("old") }))
    let published = try #require(
      relay.publish(
        ServerCommandActions(
          reconnect: { calls.append("reconnect") }, changeServer: { calls.append("change") })))
    #expect(relay.publications == 2)
    published.reconnect?()
    published.changeServer?()
    #expect(published.signOut == nil)
    #expect(calls == ["reconnect", "change"])

    let signedIn = try #require(
      relay.publish(ServerCommandActions(reconnect: {}, changeServer: {}, signOut: {})))
    #expect(relay.publications == 3)
    #expect(signedIn.signOut != nil)
  }

  @Test("the sidebar toggle hides a shown sidebar and shows a hidden one")
  func sidebarToggle() {
    #expect(SidebarToggle.toggled(.all) == .detailOnly)
    #expect(SidebarToggle.toggled(.automatic) == .detailOnly)
    #expect(SidebarToggle.toggled(.detailOnly) == .all)
    let toggle = SidebarToggle()
    var toggled = 0
    toggle()
    toggle.toggle = { toggled += 1 }
    toggle()
    #expect(toggled == 1)
  }
}
