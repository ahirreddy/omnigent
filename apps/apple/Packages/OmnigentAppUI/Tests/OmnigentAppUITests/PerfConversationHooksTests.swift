#if DEBUG
  import Foundation
  import OmnigentUIComponents
  import SwiftUI
  import Testing

  @testable import OmnigentAppUI

  /// What the performance scripts' hooks do to a shown conversation.
  @MainActor
  @Suite("Performance hooks")
  struct PerfConversationHooksTests {
    private final class Panel {
      var isShown = true
      var tab = InspectorTab.allCases[0]
      var browsers = 0
      var sideChats: [(String, Bool)] = []
    }

    private func hooks(_ panel: Panel) -> PerfConversationHooks {
      PerfConversationHooks(
        showPanel: { tab in
          if let tab { panel.tab = tab }
          panel.isShown = tab != nil
        },
        openBrowser: { panel.browsers += 1 },
        openSideChat: { panel.sideChats.append(($0, $1)) })
    }

    @Test("Each panel tab has a hook, which shows the panel on that tab")
    func panelTabs() {
      for tab in InspectorTab.allCases {
        let panel = Panel()
        panel.isShown = false
        let hook = "panel.\(tab.rawValue)"
        #expect(PerfConversationHooks.names.contains(hook))
        hooks(panel).perform(hook)
        #expect(panel.isShown)
        #expect(panel.tab == tab)
      }
    }

    @Test("Close hides the panel; an unknown hook changes nothing")
    func closingAndUnknown() {
      let panel = Panel()
      let before = panel.tab
      hooks(panel).perform("panel.nothing")
      #expect(panel.isShown)
      #expect(panel.tab == before)
      hooks(panel).perform("panel.close")
      #expect(!panel.isShown)
    }

    @Test("The browser and side chat hooks open them, the question asked at once")
    func opening() {
      let panel = Panel()
      hooks(panel).perform("browser")
      hooks(panel).perform("sidechat.open")
      hooks(panel).perform("sidechat.ask")
      #expect(panel.browsers == 1)
      #expect(panel.sideChats.map(\.0) == ["", "What does a side chat see?"])
      #expect(panel.sideChats.map(\.1) == [false, true])
    }

    @Test("The panel hooks show and hide the window's panel where it has one, else the chat's own")
    func panelOwners() {
      let tab = InspectorTab.allCases[InspectorTab.allCases.count - 1]
      let window = SessionChromeState(viewChoice: SessionViewChoice()) {}
      var ownShown = false
      var ownTab = InspectorTab.allCases[0]
      let own = (
        panel: Binding(get: { ownShown }, set: { ownShown = $0 }),
        tab: Binding(get: { ownTab }, set: { ownTab = $0 })
      )
      let showWindows = PerfConversationHooks.showingPanel(
        window: window, ownPanel: own.panel, ownTab: own.tab)
      showWindows(tab)
      #expect(window.panel.isShown)
      #expect(window.inspectorTab == tab)
      showWindows(nil)
      #expect(!window.panel.isShown)
      #expect(window.inspectorTab == tab, "hiding keeps the tab")
      #expect(!ownShown && ownTab == InspectorTab.allCases[0], "the chat's own is left alone")

      let showOwn = PerfConversationHooks.showingPanel(
        window: nil, ownPanel: own.panel, ownTab: own.tab)
      showOwn(tab)
      #expect(ownShown)
      #expect(ownTab == tab)
      showOwn(nil)
      #expect(!ownShown)
      #expect(ownTab == tab)
    }
  }
#endif
