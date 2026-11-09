#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Tabs: the + button's menu", .serialized)
  @MainActor
  struct TabsNewTabMenuTests {
    private func controls(
      _ state: NewTabPageState, _ page: NewTabPageActions, spy: TabSpy,
      defaults: UserDefaults? = nil
    ) throws -> OffscreenWindow<AnyView> {
      var actions = spy.basicActions
      actions.newTabMenu = { NewTabOptions(state: state, actions: page) }
      let view = TabStripControls(state: TabFixture.pair, actions: actions)
        .defaultAppStorage(try defaults ?? TabFixture.scratchDefaults())
        .frame(width: 300, height: 400)
      return OffscreenWindow(AnyView(view), width: 300, height: 400)
    }

    @Test("It lists what the session opens, with icons; each opens in a new tab")
    func everyItem() throws {
      let spy = TabSpy()
      let screen = try controls(
        NewTabPageState(canOpenBrowser: true), spy.newTabActions, spy: spy)
      defer { screen.close() }
      let menu = try screen.openMenu(control: 0)
      #expect(menu.titles == ["Side Chat", "Terminal", "Browser", "Remote Browser"])
      // A pull-down menu can lead with a separator standing in for its title item.
      #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
      for title in menu.titles { try screen.choose(title, in: try screen.openMenu(control: 0)) }
      #expect(spy.calls == ["side chat", "terminal -", "browser", "remote default"])
    }

    @Test("What the session can't open is left out")
    func leftOut() throws {
      let spy = TabSpy()
      var page = spy.newTabActions
      page.newSideChat = nil
      page.openRemoteBrowser = nil
      let screen = try controls(NewTabPageState(canOpenBrowser: false), page, spy: spy)
      defer { screen.close() }
      #expect(try screen.openMenu(control: 0).titles == ["Terminal"])
    }

    @Test("With nothing to open, + opens the New Tab page")
    func nothingToOpen() throws {
      let spy = TabSpy()
      let screen = try controls(
        NewTabPageState(canOpenBrowser: true), NewTabPageActions(), spy: spy)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["new tab"])
    }

    @Test("Terminal is there but disabled when the agent declares none")
    func noTerminals() throws {
      let spy = TabSpy()
      let screen = try controls(
        NewTabPageState(terminals: .declared([])), spy.newTabActions, spy: spy)
      defer { screen.close() }
      let menu = try screen.openMenu(control: 0)
      #expect(try #require(menu.item(named: "Terminal")).isEnabled == false)
    }

    @Test("A session's one terminal opens by name")
    func oneTerminal() throws {
      let spy = TabSpy()
      let screen = try controls(
        NewTabPageState(terminals: .declared(["build"])), spy.newTabActions, spy: spy)
      defer { screen.close() }
      try screen.choose("Terminal", in: try screen.openMenu(control: 0))
      #expect(spy.calls == ["terminal build"])
    }

    @Test("Of several terminals it names the one it opens; another picked is remembered")
    func severalTerminals() throws {
      let spy = TabSpy()
      let defaults = try TabFixture.scratchDefaults()
      let state = NewTabPageState(terminals: .declared(["zsh", "bash", "fish"]))
      let screen = try controls(state, spy.newTabActions, spy: spy, defaults: defaults)
      defer { screen.close() }
      let menu = try screen.openMenu(control: 0)
      #expect(menu.titles == ["Side Chat", "Terminal (zsh)", "Other Terminals", "Remote Browser"])
      #expect(menu.item(named: "Other Terminals")?.submenu?.titles == ["bash", "fish"])
      try screen.choose("Terminal (zsh)", in: menu)
      try screen.choose("fish", in: try screen.openMenu(control: 0))
      #expect(spy.calls == ["terminal zsh", "terminal fish"])
      #expect(defaults.string(forKey: PreferredTerminal.key) == "fish")

      let again = try screen.openMenu(control: 0)
      #expect(again.item(named: "Terminal (fish)") != nil)
      #expect(again.item(named: "Other Terminals")?.submenu?.titles == ["zsh", "bash"])
    }

    @Test("A remembered terminal this session doesn't declare leaves its first")
    func rememberedElsewhere() throws {
      let defaults = try TabFixture.scratchDefaults()
      defaults.set("nu", forKey: PreferredTerminal.key)
      let spy = TabSpy()
      let screen = try controls(
        NewTabPageState(terminals: .declared(["zsh", "bash"])), spy.newTabActions, spy: spy,
        defaults: defaults)
      defer { screen.close() }
      try screen.choose("Terminal (zsh)", in: try screen.openMenu(control: 0))
      #expect(spy.calls == ["terminal zsh"])
    }

    @Test("Remote Browser offers each of the machine's profiles")
    func remoteProfiles() throws {
      let spy = TabSpy()
      let screen = try controls(
        NewTabPageState(remoteBrowserProfiles: ["work", "home"]), spy.newTabActions, spy: spy)
      defer { screen.close() }
      let menu = try screen.openMenu(control: 0)
      #expect(menu.item(named: "Remote Browser")?.submenu?.titles == ["work", "home"])
      try screen.choose("home", in: menu)
      #expect(spy.calls == ["remote home"])
    }

    @Test("The remembered terminal counts only while the session declares it")
    func preferredTerminal() throws {
      #expect(PreferredTerminal.resolve(["zsh", "bash"], preferred: nil) == "zsh")
      #expect(PreferredTerminal.resolve(["zsh", "bash"], preferred: "bash") == "bash")
      #expect(PreferredTerminal.resolve(["zsh", "bash"], preferred: "fish") == "zsh")
      #expect(PreferredTerminal.resolve([], preferred: "bash") == nil)
      let defaults = try TabFixture.scratchDefaults()
      #expect(PreferredTerminal.stored(in: defaults) == nil)
      defaults.set("fish", forKey: PreferredTerminal.key)
      #expect(PreferredTerminal.stored(in: defaults) == "fish")
    }
  }
#endif
