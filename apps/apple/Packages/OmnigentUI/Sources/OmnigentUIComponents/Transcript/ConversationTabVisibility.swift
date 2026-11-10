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

/// A chat's transcript while its terminal shows or its tab is hidden: kept built, as a hidden
/// tab's content is, so going back to Chat shows it where it was.
struct HiddenUnderTerminal: ViewModifier {
  let showsTerminal: Bool
  @Environment(\.isTabContentHidden) private var isHiddenTab

  func body(content: Content) -> some View {
    content.modifier(HiddenTabContent(isHidden: showsTerminal || isHiddenTab))
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
  /// Every command but who answers Command-Return, which this reads itself.
  let commands: SessionCommandActions
  let commandReturn: CommandReturnArbitration
  let relay: FocusedActionsRelay<SessionCommandActions>
  @Environment(\.isActiveTabPane) private var isActivePane

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.sessionCommands, relay.publish(isActivePane ? resolved : nil))
  }

  /// Send Message while the draft can go; otherwise the request's Approve may own the key.
  private var resolved: SessionCommandActions {
    var commands = commands
    if !commandReturn.canSend { commands.send = nil }
    commands.approveOwnsCommandReturn = commandReturn.owner == .approve
    return commands
  }
}
