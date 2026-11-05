#if DEBUG
  import OmnigentPlatform
  import OmnigentUIComponents
  import SwiftUI

  /// The shown conversation's measurement hooks (docs/performance.md): the right panel's tabs
  /// (`ai.omnigent.perf.panel.<tab>`, `panel.close`) and a browser tab (`browser`).
  struct PerfConversationHooks: ViewModifier {
    @Binding var showsInspector: Bool
    @Binding var inspectorTab: InspectorTab
    let openBrowser: (@MainActor () -> Void)?
    @Environment(\.isTabContentHidden) private var isHidden

    func body(content: Content) -> some View {
      content.perfHooks(
        ["panel.close", "browser"] + InspectorTab.allCases.map { "panel.\($0.rawValue)" }
      ) { hook in
        guard !isHidden else { return }
        switch hook {
        case "panel.close": showsInspector = false
        case "browser": openBrowser?()
        default:
          guard let tab = InspectorTab(rawValue: String(hook.dropFirst("panel.".count))) else {
            return
          }
          inspectorTab = tab
          showsInspector = true
        }
      }
    }
  }
#endif
