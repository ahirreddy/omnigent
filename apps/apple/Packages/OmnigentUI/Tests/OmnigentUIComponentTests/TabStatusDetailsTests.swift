import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("The tab strip reads the selected chat's status line itself")
@MainActor
struct TabStatusDetailsTests {
  final class Owner {}

  @Test("Readers with the same owner are equal, so the strip does not redraw for a new one")
  func equalByOwner() {
    let owner = Owner()
    let first = TabStatusDetails(owner: owner) { _ in "one" }
    let second = TabStatusDetails(owner: owner) { _ in "two" }
    #expect(first == second)
    #expect(first != TabStatusDetails(owner: Owner()) { _ in nil })
    #expect(second.detail(of: "tab") == "two")
  }

  @Test("The shown conversation's toolbar items win over hidden tabs' empty ones")
  func toolbarKeyKeepsTheShownItems() {
    var value: ConversationToolbarItems?
    ConversationToolbarKey.reduce(value: &value) { nil }
    #expect(value == nil)
    ConversationToolbarKey.reduce(value: &value) { Self.items("shown") }
    ConversationToolbarKey.reduce(value: &value) { nil }
    ConversationToolbarKey.reduce(value: &value) { Self.items("other") }
    #expect(value?.state.header.id == "shown")
  }

  private static func items(_ id: String) -> ConversationToolbarItems {
    ConversationToolbarItems(
      state: ConversationViewState(header: SessionHeader(id: id, title: id)),
      extras: ConversationExtras(), offersTerminal: false, tabsInTitlebar: true, isRegular: true,
      showsProjectTag: false, mode: .constant(.chat), showsInspector: .constant(false),
      showsInfo: .constant(false), showShare: {}, titleMenu: AnyView(EmptyView()))
  }
}
