import SwiftUI

extension EnvironmentValues {
  /// A tab host places the shown conversation's toolbar items itself (``KeptAliveTabs``), so
  /// switching between conversations updates the same items instead of replacing them.
  @Entry var hostsConversationToolbar = false
}

extension EnvironmentValues {
  /// The session's chat tab in the titlebar's strip carries the Chat / Terminal switch, as on
  /// a Mac; elsewhere the switch leads the toolbar's trailing items.
  @Entry var tabCarriesViewSwitch: Bool = {
    #if os(macOS)
      return true
    #else
      return false
    #endif
  }()
}

/// The conversation's toolbar items and what they act on: Agent info, the session menu, Share
/// and the right-panel toggle, led by the Chat / Terminal switch where no tab carries it.
struct ConversationToolbarItems {
  let state: ConversationViewState
  let extras: ConversationExtras
  let offersTerminal: Bool
  let tabsInTitlebar: Bool
  let isRegular: Bool
  /// The session's chat tab carries the Chat / Terminal switch, so the toolbar has none.
  var tabCarriesViewSwitch = false
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
    // The tabs hold the titlebar's middle, so the switch leads the trailing items there; at
    // compact width it leads the title menu, so the title stays.
    if items.offersTerminal, items.isRegular, !items.tabCarriesViewSwitch {
      ToolbarItem(placement: items.tabsInTitlebar ? .primaryAction : .principal) {
        ViewModePicker(mode: items.mode, status: items.state.terminal)
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      let state = items.state
      #if os(macOS)
        if let sandbox = state.sandbox {
          SandboxStatusControl(state: sandbox, actions: items.extras.sandbox)
        }
      #endif
      if let info = state.agentInfo, !(info.tools.isEmpty && info.policies.isEmpty) {
        Button("Agent info", systemImage: "info.circle") { items.showsInfo.wrappedValue.toggle() }
          .popover(isPresented: items.showsInfo) { AgentInfoPopover(info: info) }
          .help("Agent info")
          .accessibilityIdentifier("header-agent-info")
      }
      // The title menu's commands, Move session and Share among them, when the titlebar holds
      // the tabs.
      if items.tabsInTitlebar {
        SessionActionsButton { items.titleMenu }
      }
      // At compact width Share lives in the title menu; the top corner is out of thumb reach.
      if items.extras.share != nil, items.isRegular {
        Button("Share", systemImage: "person.badge.plus", action: items.showShare)
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
