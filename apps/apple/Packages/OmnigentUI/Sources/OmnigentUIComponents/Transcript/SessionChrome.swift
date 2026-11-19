public import SwiftUI

extension EnvironmentValues {
  /// The window shows its session's toolbar controls and right panel around its tabs
  /// (``SessionChrome``), so a conversation inside shows neither.
  @Entry var hostsSessionChrome = false
}

/// A session's toolbar controls (Agent info, the session menu, Share and the right-panel
/// toggle, with the Chat / Terminal switch where no tab carries it) and its right panel, with
/// what they act on.
public struct SessionChrome {
  let state: ConversationViewState
  let extras: ConversationExtras
  let actions: ConversationActions
  let mode: Binding<SessionViewMode>
  let showsInspector: Binding<Bool>
  let inspectorTab: Binding<InspectorTab>
  let fork: Binding<ForkViewState?>

  /// Creates the chrome.
  /// - Parameters:
  ///   - state: The session's conversation; its rows are not read.
  ///   - extras: The session menu, the right panel's content and Share.
  ///   - actions: What the right panel opens.
  ///   - mode: Chat or Terminal.
  ///   - showsInspector: Whether the right panel shows.
  ///   - inspectorTab: The right panel's tab.
  ///   - fork: The Fork dialog's state; non-`nil` shows it.
  public init(
    state: ConversationViewState, extras: ConversationExtras, actions: ConversationActions,
    mode: Binding<SessionViewMode>, showsInspector: Binding<Bool>,
    inspectorTab: Binding<InspectorTab>, fork: Binding<ForkViewState?>
  ) {
    self.state = state
    self.extras = extras
    self.actions = actions
    self.mode = mode
    self.showsInspector = showsInspector
    self.inspectorTab = inspectorTab
    self.fork = fork
  }
}

extension View {
  /// Shows a window's session around its tabs: its toolbar controls, whichever tab or pane has
  /// the focus, and its right panel at the trailing edge, beside every pane. The conversations
  /// inside leave both to the window.
  /// - Parameters:
  ///   - chrome: The shown session's; `nil` on a page without a session.
  ///   - panelShown: Whether the panel shows: the shown session's, also while `chrome` is
  ///     `nil` before its chat opens, or a page's. `nil` binds the chrome's own.
  /// - Returns: The view.
  public func sessionChrome(_ chrome: SessionChrome?, panelShown: Binding<Bool>? = nil)
    -> some View
  {
    modifier(WindowSessionChrome(chrome: chrome, panelShown: panelShown))
  }
}

/// The session chrome of a window: one place for every tab, so switching tabs or panes neither
/// moves the right panel nor changes a toolbar item.
private struct WindowSessionChrome: ViewModifier {
  let chrome: SessionChrome?
  let panelShown: Binding<Bool>?
  /// A page without a session forks nothing (`.constant` counts as changed on every update).
  @State private var noFork: ForkViewState?

  func body(content: Content) -> some View {
    content
      .environment(\.hostsSessionChrome, true)
      .modifier(SessionChromeParts(chrome: chrome, isOwn: false, panelShown: panelShown))
      .sheet(item: ForkSheetID.binding(chrome?.fork ?? $noFork)) { _ in
        if let fork = chrome?.fork.wrappedValue, let actions = chrome?.extras.forkActions {
          ForkSheet(state: fork, actions: actions)
        }
      }
  }
}

/// A conversation's own chrome, where no window shows its session's.
struct OwnSessionChrome: ViewModifier {
  let chrome: SessionChrome
  @Environment(\.hostsSessionChrome) private var isHosted

  func body(content: Content) -> some View {
    if isHosted {
      content
        .holdsSizeWhileTabHidden()
        .unmeasuredMinimum(UnmeasuredMinimum.column)
        // A hidden tab publishes no title, so the shown tab keeps the window's.
        .background { ShownTabOnly { SessionWindowTitle(state: chrome.state) } }
    } else {
      content.modifier(SessionChromeParts(chrome: chrome, isOwn: true))
    }
  }
}

/// The window title with the one status line ("Waiting for you · 2 requests"); the project
/// shows in the sidebar.
struct SessionWindowTitle: View {
  let state: ConversationViewState

  var body: some View {
    Color.clear
      .navigationTitle(state.header.title)
      .navigationSubtitle(SessionStatusLine(state).text)
  }
}

/// The session menu's prompts: Share, Rename, and the Delete, Leave and Stop confirmations.
struct SessionMenuPrompts {
  var showsShare = false
  var showsSwitchHost = false
  var renaming: SessionSummary?
  var renameText = ""
  var confirmingDelete: SessionSummary?
  var confirmingLeave: SessionSummary?
  var confirmingStop: SessionSummary?
}

/// The toolbar controls, the right panel and the session menu's sheets, for a conversation's
/// own screen or for a window's session.
struct SessionChromeParts: ViewModifier {
  let chrome: SessionChrome?
  /// A conversation's own chrome, which names the window and follows its tab; a window's
  /// session chrome shows for every tab, and the tabs name the window.
  let isOwn: Bool
  /// Whether the panel shows, when the window binds it apart from the session's chrome.
  var panelShown: Binding<Bool>?

  @State private var prompts = SessionMenuPrompts()
  @State private var showsInfo = false
  /// What a page without a session binds (`.constant` counts as changed on every update).
  @State private var noPanel = false
  @State private var noTab = InspectorTab.files
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.transcriptWindow) private var transcriptWindow
  @Environment(\.openAppearanceSettings) private var openAppearanceSettings
  @Environment(\.tabsInTitlebar) private var tabsInTitlebar
  @Environment(\.offersTerminalView) private var offersTerminalView
  @Environment(\.tabCarriesViewSwitch) private var tabsCarryViewSwitch

  private static let noSession = ConversationViewState(header: SessionHeader(id: "", title: ""))

  func body(content: Content) -> some View {
    content
      .workspaceInspector(
        state: chrome?.state ?? Self.noSession, actions: chrome?.actions ?? ConversationActions(),
        slots: chrome?.extras.slots ?? WorkspaceSlots(),
        isPresented: panelShown ?? chrome?.showsInspector ?? $noPanel,
        tab: chrome?.inspectorTab ?? $noTab,
        holdsTabSize: isOwn
      )
      .background { if isOwn, let chrome { ShownTabOnly { windowTitle(chrome) } } }
      .modifier(SessionTrailingItems(count: chrome.map(trailingItems), isOwn: isOwn))
      .modifier(ActivePaneToolbar(items: chrome.map(toolbarItems)))
      .sheet(isPresented: $prompts.showsShare) {
        if let share = chrome?.extras.share {
          ShareSheet(state: share.state, actions: share.actions) { prompts.showsShare = false }
            .onAppear { chrome?.extras.shareOpened?() }
        }
      }
      .sheet(isPresented: $prompts.showsSwitchHost) {
        if let route = chrome?.extras.switchHost {
          HostMoveSheet(kind: route.kind, actions: route.actions) {
            prompts.showsSwitchHost = false
          }
        }
      }
      .modifier(
        SessionMenuDialogs(
          renaming: $prompts.renaming, renameText: $prompts.renameText,
          confirmingDelete: $prompts.confirmingDelete, confirmingLeave: $prompts.confirmingLeave,
          confirmingStop: $prompts.confirmingStop,
          actions: chrome?.extras.sessionActions ?? SessionListActions(),
          branch: chrome?.extras.menuContext.branch)
      )
  }

  /// Only a chat whose harness has a terminal offers the terminal view.
  private func offersTerminal(_ chrome: SessionChrome) -> Bool {
    chrome.state.terminalAvailable && offersTerminalView
  }

  /// The session's chat tab in the titlebar's strip carries the Chat / Terminal switch.
  private var tabCarriesViewSwitch: Bool { tabsInTitlebar && tabsCarryViewSwitch }

  /// The Chat / Terminal switch shows among the trailing toolbar items, beside the tabs.
  private func showsViewSwitch(_ chrome: SessionChrome) -> Bool {
    offersTerminal(chrome) && tabsInTitlebar && layoutWidth == .regular && !tabCarriesViewSwitch
  }

  private func trailingItems(_ chrome: SessionChrome) -> Int {
    TitlebarTrailingItems.count(
      chrome.state, hasShare: chrome.extras.share != nil, tabsInTitlebar: tabsInTitlebar,
      isRegular: layoutWidth == .regular)
      + (showsViewSwitch(chrome) ? TitlebarTrailingItems.viewSwitch : 0)
  }

  private func toolbarItems(_ chrome: SessionChrome) -> ConversationToolbarItems {
    ConversationToolbarItems(
      state: chrome.state, extras: chrome.extras, offersTerminal: offersTerminal(chrome),
      tabsInTitlebar: tabsInTitlebar, isRegular: layoutWidth == .regular,
      tabCarriesViewSwitch: tabCarriesViewSwitch, mode: chrome.mode,
      showsInspector: chrome.showsInspector, showsInfo: $showsInfo,
      showShare: { prompts.showsShare = true }, titleMenu: AnyView(titleMenu(chrome)))
  }

  private func windowTitle(_ chrome: SessionChrome) -> some View {
    SessionWindowTitle(state: chrome.state).toolbarTitleMenu { titleMenu(chrome) }
  }

  @ViewBuilder
  private func titleMenu(_ chrome: SessionChrome) -> some View {
    let state = chrome.state
    // Where the tab carries the switch, the menu has it too: the strip can fold away.
    if offersTerminal(chrome), layoutWidth == .compact || tabCarriesViewSwitch {
      CompactViewModeItems(mode: chrome.mode)
    }
    if let summary = state.summary {
      sessionMenu(summary, chrome).items
    } else {
      ConfirmedCopyButton(
        title: "Copy Session ID", systemImage: "number", text: state.header.id,
        confirmation: "Session ID copied")
    }
    // As the web's host menu: move the session to another machine, online host or not.
    if chrome.extras.switchHost != nil {
      Button("Switch Host\u{2026}", systemImage: "arrow.left.arrow.right") {
        prompts.showsSwitchHost = true
      }
      .accessibilityIdentifier("header-switch-host")
    }
    if let exportTranscript = chrome.extras.exportTranscript {
      Button("Export\u{2026}", systemImage: "square.and.arrow.down", action: exportTranscript)
        .accessibilityIdentifier("header-export-conversation")
    }
    if let open = chrome.actions.openSession {
      if let parentID = state.parentSessionID ?? state.sideChatSourceID {
        Button("Go to Parent Session", systemImage: "chevron.backward") { open(parentID) }
      }
      if let creator = chrome.extras.menuContext.createdBy {
        Button("Go to Creating Session", systemImage: "arrow.up.backward") { open(creator.id) }
      }
    }
    if layoutWidth == .compact {
      CompactPanelItems(labels: InspectorTabLabels(state: state, slots: chrome.extras.slots)) {
        chrome.showPanel($0)
      }
    }
    transcriptTitleMenuItems(
      TranscriptTitleMenu(window: transcriptWindow, openAppearance: openAppearanceSettings))
  }

  /// The sidebar row's menu for this session (as the web's header menu mirrors its row), with
  /// Share opening this chrome's sheet.
  private func sessionMenu(_ summary: SessionSummary, _ chrome: SessionChrome) -> SessionRowMenu {
    var actions = chrome.extras.sessionActions
    actions.share = nil
    // Nests are the sidebar's, as on the web; the header files into projects only.
    actions.moveToNest = nil
    if chrome.extras.share != nil {
      let present: @MainActor (SessionSummary) -> Void = { _ in prompts.showsShare = true }
      actions.share = present
    }
    let context = chrome.extras.menuContext
    var menu = SessionRowMenu(
      session: summary, isUnread: false, isShared: context.isShared, pinLimitReached: false,
      projects: context.projects, actions: actions,
      rename: {
        prompts.renameText = summary.title
        prompts.renaming = summary
      },
      confirmDelete: { prompts.confirmingDelete = summary },
      confirmLeave: { prompts.confirmingLeave = summary },
      confirmStop: { prompts.confirmingStop = summary },
      project: context.projects.first { $0.id == context.projectID })
    menu.shareUnavailableReason = chrome.state.shareUnavailableReason
    return menu
  }
}

extension SessionChrome {
  /// Shows the right panel on `tab`, setting aside any open file or diff.
  func showPanel(_ tab: InspectorTab) {
    if let show = extras.showPanelTab {
      show(tab)
    } else {
      inspectorTab.wrappedValue = tab
      extras.slots.documents?.showPanel()
      showsInspector.wrappedValue = true
    }
  }
}

/// The titlebar space the session's trailing toolbar items take. A conversation's own count
/// follows its tab; a window's session adds its count to what the shown tab's page shows.
private struct SessionTrailingItems: ViewModifier {
  let count: Int?
  let isOwn: Bool

  func body(content: Content) -> some View {
    if isOwn {
      content.modifier(ShownTabTrailingItems(count: count ?? 0))
    } else {
      content.transformPreference(TitlebarTrailingItems.self) { items in
        if let count { items = count + (items ?? 0) }
      }
    }
  }
}
