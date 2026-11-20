import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// Back and Forward over the pages a window showed, as the web's history steps its routes.
@MainActor
@Suite("Page history")
struct PageHistoryTests {
  @Test("Back returns through the pages shown, Forward retraces them, and a new page drops ahead")
  func steps() {
    let tabs = SessionTabGroups()
    tabs.show(.session("a"))
    tabs.show(.inbox)
    tabs.show(.session("b"))
    #expect(tabs.history.canGoBack && !tabs.history.canGoForward)
    tabs.goBack()
    #expect(tabs.page == .inbox)
    tabs.goBack()
    #expect(tabs.page == .session("a"))
    #expect(!tabs.history.canGoBack)
    tabs.goBack()
    #expect(tabs.page == .session("a"), "Back stops at the first page")
    tabs.goForward()
    #expect(tabs.page == .inbox)
    tabs.show(.automations)
    #expect(!tabs.history.canGoForward, "a new page drops what was ahead")
    tabs.goBack()
    #expect(tabs.page == .inbox)
  }

  @Test("Showing the shown page again records nothing")
  func samePage() {
    let tabs = SessionTabGroups()
    tabs.show(.session("a"))
    tabs.show(.session("a"))
    #expect(!tabs.history.canGoBack)
  }

  @Test("A removed session leaves the history, without repeats side by side")
  func removed() {
    var history = PageHistory()
    history.leave(.inbox)
    history.leave(.session("gone"))
    history.leave(.inbox)
    history.remove(sessions: ["gone"])
    #expect(history.back == [.inbox])
    let tabs = SessionTabGroups()
    tabs.show(.session("a"))
    tabs.show(.session("b"))
    tabs.removeSessions(["a"])
    #expect(!tabs.history.canGoBack)
  }

  @Test("The history keeps the newest fifty pages")
  func limit() {
    var history = PageHistory()
    for index in 0..<60 { history.leave(.session("s\(index)")) }
    #expect(history.back.count == PageHistory.limit)
    #expect(history.back.first == .session("s10"))
  }
}
