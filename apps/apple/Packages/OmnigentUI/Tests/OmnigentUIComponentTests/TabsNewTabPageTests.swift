#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Tabs: the new tab page", .serialized)
  @MainActor
  struct TabsNewTabPageTests {
    private let one = SessionSummary(id: "one", title: "One", agentName: "Coder")
    private let two = SessionSummary(id: "two", title: "Two", attention: .needsYou)
    private let three = SessionSummary(id: "three", title: "Three")
    private let four = SessionSummary(id: "four", title: "Four")

    private func page(_ state: NewTabPageState, _ actions: NewTabPageActions)
      -> OffscreenWindow<AnyView>
    {
      let view = NewTabPage(state: state, actions: actions).frame(width: 800, height: 700)
      return OffscreenWindow(AnyView(view), width: 800, height: 700)
    }

    private func allActions(_ spy: TabSpy) -> NewTabPageActions {
      var actions = NewTabPageActions(
        newSession: { spy.calls.append("new session") },
        newTerminal: { spy.calls.append("terminal \($0) \($1 ?? "-")") },
        openBrowser: { spy.calls.append("browser") },
        openSession: { spy.calls.append("open \($0)") })
      actions.openRemoteBrowser = { spy.calls.append("remote \($0) \($1)") }
      return actions
    }

    @Test("New Session starts one")
    func newSession() throws {
      let spy = TabSpy()
      let screen = page(NewTabPageState(), allActions(spy))
      defer { screen.close() }
      #expect(try screen.shows("New Tab"))
      #expect(try screen.shows("Start an agent on a task"))
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["new session"])
    }

    @Test("Browser shows only when the server has a web app")
    func browser() throws {
      let spy = TabSpy()
      let screen = page(NewTabPageState(canOpenBrowser: true), allActions(spy))
      defer { screen.close() }
      #expect(try screen.shows("Browser"))
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["browser"])
      let without = page(NewTabPageState(), allActions(spy))
      defer { without.close() }
      #expect(try !without.shows("Open this server's web app"))
    }

    @Test("Launchers without an action aren't offered")
    func onlySession() throws {
      let screen = page(NewTabPageState(canOpenBrowser: true), NewTabPageActions())
      defer { screen.close() }
      #expect(try !screen.shows("Terminal"))
      #expect(try !screen.shows("Browser"))
      #expect(try !screen.shows("Remote Browser"))
    }

    @Test("With no sessions Terminal and Remote Browser are shown but disabled")
    func disabledWithoutSessions() throws {
      let screen = page(NewTabPageState(), allActions(TabSpy()))
      defer { screen.close() }
      #expect(try screen.shows("Terminal"))
      #expect(try screen.shows("Remote Browser"))
      #expect(screen.controlFrames.count == 1)
    }

    @Test("Recent sessions open, at most eight")
    func recent() throws {
      let spy = TabSpy()
      let sessions = (0..<10).map { SessionSummary(id: "s\($0)", title: "Session \($0)") }
      let screen = page(NewTabPageState(recentSessions: sessions), allActions(spy))
      defer { screen.close() }
      #expect(try screen.shows("RECENT SESSIONS"))
      #expect(try screen.shows("Session 7"))
      #expect(try !screen.shows("Session 8"))
      // New Session, Terminal, Remote Browser, then the sessions.
      try screen.clickControl(at: 3)
      #expect(spy.calls == ["open s0"])
    }

    @Test("A recent session names its agent and its needs-you dot")
    func recentDetails() throws {
      let screen = page(NewTabPageState(recentSessions: [one, two]), allActions(TabSpy()))
      defer { screen.close() }
      #expect(try screen.shows("Coder"))
      func picture(_ session: SessionSummary) throws -> Data {
        try RenderSupport.picture(
          NewTabPage(
            state: NewTabPageState(recentSessions: [session]), actions: NewTabPageActions()),
          width: 500, height: 500)
      }
      let plain = SessionSummary(id: "two", title: "Two")
      #expect(try picture(two) != picture(plain))
    }

    @Test("Without any recent session the section is gone")
    func noRecent() throws {
      let screen = page(NewTabPageState(), allActions(TabSpy()))
      defer { screen.close() }
      #expect(try !screen.shows("RECENT SESSIONS"))
    }

    @Test("Terminal's menu is by what each session declares")
    func terminalChoices() throws {
      let spy = TabSpy()
      let state = NewTabPageState(
        recentSessions: [one, two, three, four],
        terminalNames: ["two": [], "three": ["shell"], "four": ["build", "test"]])
      let screen = page(state, allActions(spy))
      defer { screen.close() }
      let menu = try screen.openMenu(control: 1)
      #expect(
        menu.titles == [
          "One", "Two: no terminals declared", "Three \u{2014} shell", "Four",
        ])
      #expect(menu.item(named: "Two: no terminals declared")?.isEnabled == false)
      try screen.choose("One", in: menu)
      try screen.choose("Three \u{2014} shell", in: screen.openMenu(control: 1))
      try screen.choose("test", in: screen.openMenu(control: 1))
      #expect(spy.calls == ["terminal one -", "terminal three shell", "terminal four test"])
    }

    @Test("Remote Browser asks for a session, then a profile")
    func remoteBrowser() throws {
      let spy = TabSpy()
      let state = NewTabPageState(recentSessions: [one], remoteBrowserProfiles: ["work", "home"])
      let screen = page(state, allActions(spy))
      defer { screen.close() }
      let menu = try screen.openMenu(control: 2)
      #expect(menu.item(named: "One")?.submenu?.titles == ["work", "home"])
      try screen.choose("home", in: menu)
      #expect(spy.calls == ["remote one home"])
    }

    @Test("With no profiles Remote Browser offers the default")
    func remoteDefault() throws {
      let spy = TabSpy()
      let screen = page(NewTabPageState(recentSessions: [one]), allActions(spy))
      defer { screen.close() }
      try screen.choose("default", in: screen.openMenu(control: 2))
      #expect(spy.calls == ["remote one default"])
    }

    @Test("A compact window pads less")
    func compact() throws {
      func picture(_ layout: LayoutWidth) throws -> Data {
        let rendered = try RenderSupport.render(
          NewTabPage(state: NewTabPageState(), actions: NewTabPageActions()), width: 500,
          height: 300,
          scheme: .light, layout: layout)
        return try #require(rendered.image.tiffRepresentation)
      }
      #expect(try picture(.compact) != picture(.regular))
    }
  }
#endif
