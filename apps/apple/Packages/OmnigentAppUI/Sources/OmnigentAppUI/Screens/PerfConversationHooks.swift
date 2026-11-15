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
