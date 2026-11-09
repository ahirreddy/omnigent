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
    private func page(
      _ state: NewTabPageState, _ actions: NewTabPageActions, defaults: UserDefaults? = nil
    ) throws -> OffscreenWindow<AnyView> {
      let view = NewTabPage(state: state, actions: actions)
        .defaultAppStorage(try defaults ?? TabFixture.scratchDefaults())
        .frame(width: 800, height: 700)
      return OffscreenWindow(AnyView(view), width: 800, height: 700)
    }

    @Test("Every launcher opens in the page's session")
    func launchers() throws {
      let spy = TabSpy()
      let state = NewTabPageState(sessionTitle: "Fix the build", canOpenBrowser: true)
      let screen = try page(state, spy.newTabActions)
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
      let without = try page(NewTabPageState(), TabSpy().newTabActions)
      defer { without.close() }
      #expect(try !without.shows("Open this server's web app"))
      #expect(without.controlFrames.count == 3)
    }

    @Test("Launchers without an action aren't offered, and an empty page says so")
    func nothingToOpen() throws {
      let screen = try page(NewTabPageState(canOpenBrowser: true), NewTabPageActions())
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
      let screen = try page(NewTabPageState(terminals: .declared([])), spy.newTabActions)
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
      let screen = try page(NewTabPageState(terminals: .declared(["build"])), spy.newTabActions)
      defer { screen.close() }
      #expect(try screen.shows("build"))
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["terminal build"])
    }

    @Test("Of several terminals, one click opens the first; its name chooses another, kept")
    func terminalChoice() throws {
      let spy = TabSpy()
      let defaults = try TabFixture.scratchDefaults()
      let state = NewTabPageState(terminals: .declared(["zsh", "bash"]))
      let screen = try page(state, spy.newTabActions, defaults: defaults)
      defer { screen.close() }
      #expect(try !screen.shows("terminals"))
      let (name, card) = try terminalControls(screen)
      #expect(name.titleOfSelectedItem == "zsh")
      try screen.click(CGPoint(x: card.midX, y: card.midY))
      #expect(spy.calls == ["terminal zsh"])

      let menu = try screen.openMenu(name)
      #expect(menu.titles == ["zsh", "bash"])
      try screen.choose("bash", in: menu)
      #expect(spy.calls == ["terminal zsh"], "choosing opens nothing")
      #expect(defaults.string(forKey: PreferredTerminal.key) == "bash")
      #expect(name.titleOfSelectedItem == "bash")
      try screen.click(CGPoint(x: card.midX, y: card.midY))
      #expect(spy.calls == ["terminal zsh", "terminal bash"])

      let again = try page(state, spy.newTabActions, defaults: defaults)
      defer { again.close() }
      #expect(try terminalControls(again).name.titleOfSelectedItem == "bash", "remembered")
    }

    @Test("A remembered terminal the session doesn't declare leaves the first")
    func rememberedElsewhere() throws {
      let spy = TabSpy()
      let defaults = try TabFixture.scratchDefaults()
      defaults.set("fish", forKey: PreferredTerminal.key)
      let screen = try page(
        NewTabPageState(terminals: .declared(["zsh", "bash"])), spy.newTabActions,
        defaults: defaults)
      defer { screen.close() }
      let (name, card) = try terminalControls(screen)
      #expect(name.titleOfSelectedItem == "zsh")
      try screen.click(CGPoint(x: card.midX, y: card.midY))
      #expect(spy.calls == ["terminal zsh"])
      #expect(defaults.string(forKey: PreferredTerminal.key) == "fish", "kept for other sessions")
    }

    /// The Terminal launcher's name menu, and the launcher around it.
    private func terminalControls(_ screen: OffscreenWindow<AnyView>) throws
      -> (name: NSPopUpButton, card: CGRect)
    {
      let name = try #require(screen.allViews.compactMap { $0 as? NSPopUpButton }.first)
      let frame = name.convert(name.bounds, to: screen.host)
      let center = CGPoint(x: frame.midX, y: frame.midY)
      let card = try #require(
        screen.controlFrames.first { $0.contains(center) && $0.width > frame.width * 2 })
      return (name, card)
    }

    @Test("Remote Browser opens the machine's one profile directly, or asks among several")
    func remoteBrowser() throws {
      let spy = TabSpy()
      let single = try page(NewTabPageState(remoteBrowserProfiles: ["work"]), spy.newTabActions)
      defer { single.close() }
      try single.clickControl(at: 2)
      let several = try page(
        NewTabPageState(remoteBrowserProfiles: ["work", "home"]), spy.newTabActions)
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
