import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Tabs kept built while hidden")
struct TabKeepAliveTests {
  @Test("The selected tab and the most recently shown chats stay built, in strip order")
  func recentChats() {
    let store = TabStore()
    let first = store.open(.chat(sessionID: "s1"))
    let second = store.open(.chat(sessionID: "s2"))
    let third = store.open(.chat(sessionID: "s3"), placement: .end)
    let fourth = store.open(.chat(sessionID: "s4"), placement: .end)
    store.select(second.id)
    #expect(store.recentIDs.prefix(4) == [second.id, fourth.id, third.id, first.id])
    #expect(store.keptAlive().map(\.id) == [second.id, third.id, fourth.id])
    #expect(store.keptAlive(limit: 1).map(\.id) == [second.id])
  }

  @Test("Terminals, pages and other tabs are rebuilt; a closed chat is not kept")
  func onlyConversations() {
    let store = TabStore()
    let chat = store.open(.chat(sessionID: "s1"))
    let side = store.open(.sideChat(sessionID: "s1", rowID: "r1"))
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"))
    let blank = store.open(.newTab)
    #expect(store.keptAlive().map(\.id) == [chat.id, side.id, blank.id])
    store.select(shell.id)
    #expect(store.keptAlive().map(\.id) == [chat.id, side.id, shell.id])
    store.requestClose(side.id)
    #expect(store.keptAlive().map(\.id) == [chat.id, shell.id])
  }

  @Test("A selected terminal takes no chat's place, so the way back builds no chat again")
  func otherKindsTakeNoPlace() {
    let store = TabStore()
    let chats = ["s1", "s2", "s3"].map { store.open(.chat(sessionID: $0), placement: .end).id }
    let shell = store.open(.terminal(sessionID: "s1", terminalID: "t1"), placement: .end)
    #expect(store.keptAlive().map(\.id) == chats + [shell.id])
    #expect(store.keptAlive(limit: 1).map(\.id) == [chats[2], shell.id])
    #expect(store.keptAlive(limit: 0).map(\.id) == [shell.id])
    store.select(chats[2])
    #expect(store.keptAlive().map(\.id) == chats, "the same chats as behind the terminal")
    #expect(store.keptAlive(limit: 0).map(\.id) == [chats[2]], "the selected tab always stays")
  }

  @Test("A split window keeps only its panes' tabs")
  func split() {
    let store = TabStore()
    store.open(.chat(sessionID: "s1"))
    let right = store.open(.chat(sessionID: "s2"))
    store.show(right.id, in: .trailing)
    #expect(store.split != nil)
    #expect(store.keptAlive().map(\.id) == [store.selectedID].compactMap(\.self))
  }
}
