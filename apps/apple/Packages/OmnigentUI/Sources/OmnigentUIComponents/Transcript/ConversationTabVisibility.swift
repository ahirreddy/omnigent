import SwiftUI

// What a conversation shows only while its tab is on screen or its pane focused. Each piece
// reads the tab's state in its own body, so switching tabs does not run the conversation's.

/// Content only a shown tab has, such as the window's title: a kept, hidden tab leaves the
/// window's to the tab on screen.
struct ShownTabOnly<Content: View>: View {
  @Environment(\.isTabContentHidden) private var isHidden
  @ViewBuilder let content: Content

  var body: some View {
    if !isHidden { content }
  }
}

/// The titlebar space a shown conversation's trailing items take; a hidden tab reserves none.
struct ShownTabTrailingItems: ViewModifier {
  let count: Int
  @Environment(\.isTabContentHidden) private var isHidden

  func body(content: Content) -> some View {
    content.preference(key: TitlebarTrailingItems.self, value: isHidden ? nil : count)
  }
}

/// The focused pane's conversation toolbar; a split window's other pane and a hidden tab show
/// none.
struct ActivePaneToolbar: ViewModifier {
  let items: ConversationToolbarItems
  @Environment(\.isActiveTabPane) private var isActivePane

  func body(content: Content) -> some View {
    content.conversationToolbar(isActivePane ? items : nil)
  }
}

/// The focused pane's conversation drives the menus; another pane and a hidden tab do not.
struct ActivePaneCommands: ViewModifier {
  let commands: SessionCommandActions
  let relay: FocusedActionsRelay<SessionCommandActions>
  @Environment(\.isActiveTabPane) private var isActivePane

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.sessionCommands, relay.publish(isActivePane ? commands : nil))
  }
}
