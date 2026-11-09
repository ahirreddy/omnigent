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
    private func page(_ state: NewTabPageState, _ actions: NewTabPageActions)
      -> OffscreenWindow<AnyView>
    {
      let view = NewTabPage(state: state, actions: actions).frame(width: 800, height: 700)
      return OffscreenWindow(AnyView(view), width: 800, height: 700)
    }

    private func allActions(_ spy: TabSpy) -> NewTabPageActions {
      NewTabPageActions(
        newSideChat: { spy.calls.append("side chat") },
        newTerminal: { spy.calls.append("terminal \($0 ?? "-")") },
        openBrowser: { spy.calls.append("browser") },
        openRemoteBrowser: { spy.calls.append("remote \($0)") })
    }

    @Test("Every launcher opens in the page's session")
    func launchers() throws {
      let spy = TabSpy()
      let state = NewTabPageState(sessionTitle: "Fix the build", canOpenBrowser: true)
      let screen = page(state, allActions(spy))
      defer { screen.close() }
      #expect(try screen.shows("New Tab"))
      #expect(try screen.shows("Opens in Fix the build"))
      #expect(try !screen.shows("New Session"))
      #expect(screen.controlFrames.count == 4)
      for index in 0..<4 { try screen.clickControl(at: index) }
      #expect(spy.calls == ["side chat", "terminal -", "browser", "remote default"])
    }

    @Test("Browser shows only when the server has a web app")
    func browser() throws {
      let without = page(NewTabPageState(), allActions(TabSpy()))
      defer { without.close() }
      #expect(try !without.shows("Open this server's web app"))
      #expect(without.controlFrames.count == 3)
    }

    @Test("Launchers without an action aren't offered, and an empty page says so")
    func nothingToOpen() throws {
      let screen = page(NewTabPageState(canOpenBrowser: true), NewTabPageActions())
      defer { screen.close() }
      #expect(try !screen.shows("Side Chat"))
      #expect(try !screen.shows("Terminal"))
      #expect(try !screen.shows("Browser"))
      #expect(try !screen.shows("Opens in"))
      #expect(try screen.shows("Nothing in this session opens in a tab."))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("A session declaring no terminals shows Terminal disabled")
    func noTerminals() throws {
      let spy = TabSpy()
      let screen = page(NewTabPageState(terminals: .declared([])), allActions(spy))
      defer { screen.close() }
      #expect(try screen.shows("This session's agent declares no terminals"))
      // The disabled launcher isn't a control: Side Chat and Remote Browser are.
      #expect(screen.controlFrames.count == 2)
      for index in 0..<2 { try screen.clickControl(at: index) }
      #expect(spy.calls == ["side chat", "remote default"])
    }

    @Test("A session's one declared terminal starts directly")
    func oneTerminal() throws {
      let spy = TabSpy()
      let screen = page(NewTabPageState(terminals: .declared(["build"])), allActions(spy))
      defer { screen.close() }
      #expect(try screen.shows("build"))
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["terminal build"])
    }

    @Test("Several declared terminals are a menu")
    func terminalMenu() throws {
      let spy = TabSpy()
      let screen = page(NewTabPageState(terminals: .declared(["build", "test"])), allActions(spy))
      defer { screen.close() }
      #expect(try screen.shows("2 terminals"))
      let menu = try screen.openMenu(control: 1)
      #expect(menu.titles == ["build", "test"])
      try screen.choose("test", in: menu)
      #expect(spy.calls == ["terminal test"])
    }

    @Test("Remote Browser opens the machine's one profile directly, or asks among several")
    func remoteBrowser() throws {
      let spy = TabSpy()
      let single = page(NewTabPageState(remoteBrowserProfiles: ["work"]), allActions(spy))
      defer { single.close() }
      try single.clickControl(at: 2)
      let several = page(
        NewTabPageState(remoteBrowserProfiles: ["work", "home"]), allActions(spy))
      defer { several.close() }
      let menu = try several.openMenu(control: 2)
      #expect(menu.titles == ["work", "home"])
      try several.choose("home", in: menu)
      #expect(spy.calls == ["remote work", "remote home"])
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
