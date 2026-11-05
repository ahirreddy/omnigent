import SwiftUI

extension EnvironmentValues {
  /// A tab host places the shown conversation's toolbar items itself (``KeptAliveTabs``), so
  /// switching between conversations updates the same items instead of replacing them.
  @Entry var hostsConversationToolbar = false
}

/// The conversation's trailing toolbar items and what they act on: viewers, Agent info, the
/// project tag, the session menu, Share and the right-panel toggle.
struct ConversationToolbarItems {
  let state: ConversationViewState
  let extras: ConversationExtras
  let offersTerminal: Bool
  let tabsInTitlebar: Bool
  let isRegular: Bool
  let showsProjectTag: Bool
  let mode: Binding<SessionViewMode>
  let showsInspector: Binding<Bool>
  let showsInfo: Binding<Bool>
  let showShare: () -> Void
  let titleMenu: AnyView
}

/// The shown conversation's toolbar items, for the tab host to place.
struct ConversationToolbarKey: PreferenceKey {
  static let defaultValue: ConversationToolbarItems? = nil

  static func reduce(
    value: inout ConversationToolbarItems?, nextValue: () -> ConversationToolbarItems?
  ) {
    value = value ?? nextValue()
  }
}

/// The conversation's toolbar items.
struct ConversationToolbar: ToolbarContent {
  let items: ConversationToolbarItems

  var body: some ToolbarContent {
    // With tabs in the titlebar, the agent's TUI is its own tab (Option-Command-\\ opens it);
    // at compact width the switch leads the title menu, so the title stays.
    if items.offersTerminal, !items.tabsInTitlebar, items.isRegular {
      ToolbarItem(placement: .principal) {
        ViewModePicker(mode: items.mode, status: items.state.terminal)
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      let state = items.state
      if let presence = state.section("presence"), items.isRegular {
        ViewerStack(viewers: SectionReading.viewers(presence))
      }
      if let info = state.agentInfo, !(info.tools.isEmpty && info.policies.isEmpty) {
        Button("Agent info", systemImage: "info.circle") { items.showsInfo.wrappedValue.toggle() }
          .popover(isPresented: items.showsInfo) { AgentInfoPopover(info: info) }
          .help("Agent info")
          .accessibilityIdentifier("header-agent-info")
      }
      // At compact width the title menu's Move session files it, so the title keeps its room.
      if let summary = state.summary, items.showsProjectTag, items.isRegular,
        let move = items.extras.sessionActions.moveToProject
      {
        HeaderProjectTag(session: summary, context: items.extras.menuContext, move: move)
      }
      // The title menu's commands, Share among them, when the titlebar holds the tabs.
      if items.tabsInTitlebar {
        SessionActionsButton { items.titleMenu }
      }
      // At compact width Share lives in the title menu; the top corner is out of thumb reach.
      if items.extras.share != nil, items.isRegular {
        Button(action: items.showShare) {
          Label("Share", systemImage: "person.badge.plus")
            .labelStyle(HeaderShareLabelStyle(isCompact: false))
        }
        .buttonStyle(.bordered)
        .disabled(state.shareUnavailableReason != nil)
        .help(state.shareUnavailableReason ?? "Share this session")
        .accessibilityIdentifier("header-share")
      }
      Button {
        items.showsInspector.wrappedValue.toggle()
      } label: {
        Label("Right panel", systemImage: "sidebar.trailing")
      }
      .keyboardShortcut(AppShortcuts.rightPanel)
      .help(
        items.showsInspector.wrappedValue
          ? "Hide the right panel (Option-Command-])" : "Show the right panel (Option-Command-])"
      )
      .accessibilityIdentifier("toggle-inspector")
    }
  }
}

extension View {
  /// Shows the conversation's toolbar items, or hands them to the tab host that places them.
  /// - Parameter items: The items; `nil` shows none (a hidden tab, or a split's other pane).
  /// - Returns: The view.
  func conversationToolbar(_ items: ConversationToolbarItems?) -> some View {
    modifier(ConversationToolbarPlacement(items: items))
  }

  /// Places the toolbar items of the conversation its content shows, in one place for every
  /// tab, so switching tabs updates the items instead of removing and adding them.
  /// - Returns: The view.
  func hostsConversationToolbar() -> some View {
    environment(\.hostsConversationToolbar, true)
      .backgroundPreferenceValue(ConversationToolbarKey.self) { items in
        Color.clear
          .toolbar {
            if let items { ConversationToolbar(items: items) }
          }
          .accessibilityHidden(true)
      }
  }
}

private struct ConversationToolbarPlacement: ViewModifier {
  let items: ConversationToolbarItems?
  @Environment(\.hostsConversationToolbar) private var isHosted

  func body(content: Content) -> some View {
    if isHosted {
      content.preference(key: ConversationToolbarKey.self, value: items)
    } else {
      content.toolbar {
        if let items { ConversationToolbar(items: items) }
      }
    }
  }
}
