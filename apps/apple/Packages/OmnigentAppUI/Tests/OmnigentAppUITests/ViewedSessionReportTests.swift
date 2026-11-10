import AppKit
import Foundation
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// What the window tells the core about the chat on screen, which a part of it reads.
@MainActor
@Suite("Viewed session report", .serialized, .timeLimit(.minutes(1)))
struct ViewedSessionReportTests {
  @Observable
  final class WindowFocus {
    var isFocused = true
    var unrelated = 0
  }

  struct Report: Equatable {
    let sessionID: String?
    let isFocused: Bool
  }

  final class Reports {
    var all: [Report] = []
  }

  struct Harness: View {
    let tabs: SessionTabGroups
    let focus: WindowFocus
    let reports: Reports

    var body: some View {
      Text("window \(focus.unrelated)")
        .modifier(
          ViewedSessionReport(tabs: tabs, isWindowFocused: focus.isFocused) {
            reports.all.append(Report(sessionID: $0, isFocused: $1))
          })
    }
  }

  @Test("Each change of the chat on screen, or of the window's focus, is reported once")
  func reportsEachChange() throws {
    let tabs = SessionTabGroups()
    tabs.show(.session("a"))
    let chat = try #require(tabs.selected)
    let focus = WindowFocus()
    let reports = Reports()
    let screen = OffscreenWindow(
      Harness(tabs: tabs, focus: focus, reports: reports), width: 300, height: 200)
    defer { screen.close() }
    screen.settle(0.1)
    #expect(reports.all.isEmpty, "the window reports what it opens on itself")

    /// What `change` made the window report.
    func reported(_ change: () -> Void) -> [Report] {
      reports.all = []
      change()
      screen.settle(0.2)
      return reports.all
    }
    let shell = reported { tabs.open(.terminal(sessionID: "a", terminalID: "t")) }
    #expect(shell == [Report(sessionID: nil, isFocused: true)], "a terminal is no chat")
    let secondShell = reported { tabs.open(.terminal(sessionID: "a", terminalID: "u")) }
    #expect(secondShell.isEmpty, "still no chat on screen")
    #expect(reported { focus.unrelated += 1 }.isEmpty, "the window rendered for something else")
    let back = reported { tabs.current?.select(chat.id) }
    #expect(back == [Report(sessionID: "a", isFocused: true)])
    let switched = reported { tabs.show(.session("b")) }
    #expect(switched == [Report(sessionID: "b", isFocused: true)])
    let unfocused = reported { focus.isFocused = false }
    #expect(unfocused == [Report(sessionID: "b", isFocused: false)])
    let inbox = reported { tabs.show(.inbox) }
    #expect(inbox == [Report(sessionID: nil, isFocused: false)], "a page without a chat")
  }

  final class Pages {
    var all: [SidebarDestination?] = []
  }

  struct PageHarness: View {
    let tabs: SessionTabGroups
    let focus: WindowFocus
    let pages: Pages

    var body: some View {
      Text("window \(focus.unrelated)")
        .modifier(ShownPageReport(tabs: tabs) { pages.all.append($0) })
    }
  }

  @Test("A page the model changes is handed over once; the window's other renders hand nothing")
  func handsOverEachPage() {
    let tabs = SessionTabGroups()
    tabs.show(.session("a"))
    let focus = WindowFocus()
    let pages = Pages()
    let screen = OffscreenWindow(
      PageHarness(tabs: tabs, focus: focus, pages: pages), width: 300, height: 200)
    defer { screen.close() }
    screen.settle(0.1)
    #expect(pages.all.isEmpty, "the page the window opened on is the host's already")

    /// The pages `change` handed over.
    func handed(_ change: () -> Void) -> [SidebarDestination?] {
      pages.all = []
      change()
      screen.settle(0.2)
      return pages.all
    }
    let opened = handed { tabs.open(.terminal(sessionID: "b", terminalID: "t")) }
    #expect(opened == [.session("b")], "a tab opened in another session shows that session")
    let chat = tabs.current?.tabs.first?.id ?? ""
    let selected = handed { tabs.current?.select(chat) }
    #expect(selected.isEmpty, "a tab of the same session")
    let unrelated = handed { focus.unrelated += 1 }
    #expect(unrelated.isEmpty, "the window rendered for something else")
    let removed = handed { tabs.removeSessions(["b"]) }
    #expect(removed == [.session("a")], "the session shown before the removed one")
    let inbox = handed { tabs.show(.inbox) }
    #expect(inbox == [.inbox])
    let reset = handed { tabs.reset() }
    #expect(reset == [nil])
  }

  #if DEBUG
    @Test("Coming back to a chat's tab in the mounted window reads its session")
    func tabSwitchReadsTheSession() async throws {
      let window = try await BudgetWindow.open()
      defer { window.screen.close() }
      window.tabs.select(window.sideChatTabID)
      try await pause(window.screen, .milliseconds(200))
      #expect(await window.list.setUnread(BudgetWindow.shown, true), "the mark was saved")
      try await settle(window.screen, until: "the unread mark") {
        window.list.unreadIDs.contains(BudgetWindow.shown)
      }
      try await pause(window.screen, .milliseconds(200))
      #expect(window.list.unreadIDs.contains(BudgetWindow.shown), "unread while its chat is hidden")

      window.tabs.select(window.chatTabID)
      try await settle(window.screen, until: "the session read once its chat shows") {
        !window.list.unreadIDs.contains(BudgetWindow.shown)
      }
    }
  #endif
}
