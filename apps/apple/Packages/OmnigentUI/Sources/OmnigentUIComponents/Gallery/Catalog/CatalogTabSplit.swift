import SwiftUI

/// The tab split view: two panes with their own tabs, the strip's pane sections, and the
/// primary chats that have no close button.
enum TabSplitCatalog {
  static var entries: [CatalogEntry] {
    [
      .page(
        .tabs, "split", "Tab Split View",
        summary: "Two panes side by side, each with its own tab, a draggable divider and focus.",
        systemImage: "rectangle.split.2x1", canvas: .device([.mac, .iPadPro13, .iPadPro11, .duo]),
        keywords: ["split", "panes", "side by side", "primary chat"],
        states: [
          CatalogState(
            "chat-browser", "Chat and browser",
            note: "The left pane has focus; the strip's sections sit over their panes."
          ) { _ in AnyView(TabsPlayground(split: true)) },
          CatalogState(
            "single", "One pane",
            note: "The chats have no close button: they leave with their session."
          ) { _ in AnyView(TabsPlayground()) },
        ],
        live: { _ in AnyView(TabsPlayground(split: true)) }),
      .component(
        .tabs, "split-strip", "Split Tab Strip",
        summary: "The strip of a split window: a section per pane, the other pane's tab lighter.",
        systemImage: "rectangle.split.2x1", canvas: .fixed(width: 1_100, height: 52),
        keywords: ["split", "strip", "panes"],
        states: [
          CatalogState("left-focused", "Left pane focused") { _ in strip(focused: .leading) },
          CatalogState("right-focused", "Right pane focused") { _ in strip(focused: .trailing) },
        ]),
    ]
  }

  @MainActor private static func strip(focused: TabPane) -> AnyView {
    let model = TabsPlaygroundModel(split: true)
    model.focus(focused)
    return AnyView(
      TabStrip(state: model.state, actions: model.actions)
        .padding(.horizontal, Theme.Spacing.small)
        .frame(maxHeight: .infinity)
        .background(.bar))
  }
}
