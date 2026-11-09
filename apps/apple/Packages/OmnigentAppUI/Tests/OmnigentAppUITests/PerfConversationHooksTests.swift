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
        showsInspector: Binding(get: { panel.isShown }, set: { panel.isShown = $0 }),
        inspectorTab: Binding(get: { panel.tab }, set: { panel.tab = $0 }),
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
  }
#endif
