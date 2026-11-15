#if DEBUG
  import OmnigentPlatform
  import OmnigentUIComponents
  import SwiftUI

  /// The shown conversation's measurement hooks (docs/performance.md): the right panel's tabs
  /// (`ai.omnigent.perf.panel.<tab>`, `panel.close`), a browser tab (`browser`), and a new side
  /// chat, empty (`sidechat.open`) or asking a question at once (`sidechat.ask`).
  struct PerfConversationHooks: ViewModifier {
    /// Shows the right panel on a tab, or hides it (`nil`). A closure, not bindings: a binding
    /// reads its value as it is made, so the chat would render as the window's panel changes.
    let showPanel: @MainActor (InspectorTab?) -> Void
    let openBrowser: (@MainActor () -> Void)?
    var openSideChat: (@MainActor (String, Bool) -> Void)?
    @Environment(\.isTabContentHidden) private var isHidden

    /// The hooks a shown conversation answers.
    static var names: [String] {
      ["panel.close", "browser", "sidechat.open", "sidechat.ask"]
        + InspectorTab.allCases.map { "panel.\($0.rawValue)" }
    }

    func body(content: Content) -> some View {
      content.perfHooks(Self.names) { if !isHidden { perform($0) } }
    }

    /// Shows the right panel on a tab, or hides it (`nil`): the window's where it shows one, else
    /// the chat's own. No binding to the window's: making one reads it, so the chat would render
    /// each time the panel changes.
    static func showingPanel(
      window: SessionChromeState?, ownPanel: Binding<Bool>, ownTab: Binding<InspectorTab>
    ) -> @MainActor (InspectorTab?) -> Void {
      { tab in
        if let window {
          if let tab { window.inspectorTab = tab }
          window.panel.isShown = tab != nil
        } else {
          if let tab { ownTab.wrappedValue = tab }
          ownPanel.wrappedValue = tab != nil
        }
      }
    }

    /// Does what `hook` measures.
    func perform(_ hook: String) {
      switch hook {
      case "panel.close": showPanel(nil)
      case "browser": openBrowser?()
      case "sidechat.open": openSideChat?("", false)
      case "sidechat.ask": openSideChat?("What does a side chat see?", true)
      default:
        guard let tab = InspectorTab(rawValue: String(hook.dropFirst("panel.".count))) else {
          return
        }
        showPanel(tab)
      }
    }
  }
#endif
