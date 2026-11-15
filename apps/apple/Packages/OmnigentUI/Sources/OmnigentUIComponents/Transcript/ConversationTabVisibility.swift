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

/// The titlebar space a page's trailing toolbar items take while it shows them. A hidden tab
/// and a split's pane without focus show none (``ActivePaneToolbar``), so they reserve none.
struct ShownTabTrailingItems: ViewModifier {
  let count: Int
  @Environment(\.isTabContentHidden) private var isHidden
  @Environment(\.isActiveTabPane) private var isActivePane

  func body(content: Content) -> some View {
    let showsItems = !isHidden && isActivePane
    content.preference(key: TitlebarTrailingItems.self, value: showsItems ? count : nil)
  }
}

/// The focused pane's conversation toolbar; a split window's other pane and a hidden tab show
/// none.
struct ActivePaneToolbar: ViewModifier {
  /// The items; `nil` on a page without a session.
  let items: ConversationToolbarItems?
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

  /// Send Message while it is offered; otherwise the request's Approve may own the key.
  private var resolved: SessionCommandActions {
    var commands = commands
    let arbitration = commandReturn
    if !arbitration.offersSend {
      commands.send = nil
    } else if let send = commands.send {
      // Checked when chosen: an empty draft is not sent.
      commands.send = { if arbitration.canSend { send() } }
    }
    commands.approveOwnsCommandReturn = arbitration.owner == .approve
    return commands
  }
}
