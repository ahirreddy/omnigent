public import SwiftUI

/// The right panel, laid out like the web's workspace rail: the fixed tabs with the "Open
/// new" menu, the panel picker and the full-screen toggle, then the files and diffs open as
/// tabs, then the shown tab.
public struct WorkspaceInspector: View {
  private let state: ConversationViewState
  private let actions: ConversationActions
  private let slots: WorkspaceSlots
  @Binding private var tab: InspectorTab
  private let maximized: Binding<Bool>?

  /// Creates the panel.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - actions: Host actions.
  ///   - slots: Tab content, open files and the "Open new" menu.
  ///   - tab: The selected fixed tab.
  ///   - maximized: Whether the panel fills the conversation; `nil` hides Full Screen.
  public init(
    state: ConversationViewState, actions: ConversationActions, slots: WorkspaceSlots,
    tab: Binding<InspectorTab>, maximized: Binding<Bool>? = nil
  ) {
    self.state = state
    self.actions = actions
    self.slots = slots
    _tab = tab
    self.maximized = maximized
  }

  private var labels: InspectorTabLabels { InspectorTabLabels(state: state, slots: slots) }

  private var tabs: [InspectorTab] { labels.tabs }

  /// The fixed tab on screen; Search falls back to Files when the server has no search.
  private var shownTab: InspectorTab { tabs.contains(tab) ? tab : .files }

  private var documents: InspectorDocuments? { slots.documents }

  /// A file or diff tab is on screen instead of the fixed tab.
  private var showsDocument: Bool { documents?.selected != nil }

  /// The panel.
  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.extraSmall) {
        // Labelled tabs when they fit; otherwise symbols with tooltips.
        ViewThatFits(in: .horizontal) {
          tabPicker(showsTitles: true)
          tabPicker(showsTitles: false)
        }
        .layoutPriority(1)
        Spacer(minLength: 0)
        InspectorTrailingControls(
          openNewSections: slots.openNew, panels: tabs, documents: documents, maximized: maximized,
          label: label(for:), select: select)
      }
      .padding(Theme.Spacing.small)
      .accessibilityIdentifier("inspector-tabs")
      if let documents, !documents.tabs.isEmpty {
        InspectorDocumentStrip(documents: documents)
      }
      if !showsDocument {
        Text(label(for: shownTab))
          .font(Theme.Typography.label)
          .accessibilityAddTraits(.isHeader)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.Spacing.large)
          .padding(.bottom, Theme.Spacing.small)
      }
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(ThemeColor.surface)
    .environment(\.conversationActions, actions)
  }

  /// Shows a fixed tab, setting aside any open file or diff.
  private func select(_ item: InspectorTab) {
    documents?.showPanel()
    tab = item
  }

  @ViewBuilder
  private func tabPicker(showsTitles: Bool) -> some View {
    #if os(macOS)
      // The Mac's segmented control fills its selection with the system accent; this bar uses
      // the neutral selected surface instead.
      InspectorTabBar(
        tabs: tabs, selection: showsDocument ? nil : shownTab, showsTitles: showsTitles,
        label: label(for:), select: select)
    #else
      systemTabPicker(showsTitles: showsTitles)
    #endif
  }

  private func systemTabPicker(showsTitles: Bool) -> some View {
    Picker("Right panel tab", selection: Binding(get: { shownTab }, set: select)) {
      ForEach(tabs) { tab in
        Group {
          if showsTitles {
            Text(tab.shortTitle)
          } else {
            Label(label(for: tab), systemImage: tab.systemImage).labelStyle(.iconOnly)
          }
        }
        .help(label(for: tab))
        .accessibilityLabel(label(for: tab))
        .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .tint(Theme.secondary)
    .labelsHidden()
    .accessibilityLabel("Right panel tab")
    .accessibilityHint("Switches between files, changes, pull requests, agents and info")
  }

  private func label(for tab: InspectorTab) -> String { labels.label(for: tab) }

  @ViewBuilder private var content: some View {
    if let documents, documents.selected != nil {
      documents.content
    } else {
      switch shownTab {
      case .files:
        if let files = slots.files {
          files
        } else {
          ContentUnavailableView(
            "Files", systemImage: "folder",
            description: Text("The session's files appear here when its host is connected."))
        }
      case .changes:
        if let changes = slots.changes {
          changes
        } else {
          ChangedFilesFallback(state: state)
        }
      case .search:
        slots.search
      case .pullRequests:
        if let pullRequests = slots.pullRequests {
          PullRequestsPanel(
            state: pullRequests, extras: slots.pullRequestPanel, open: actions.openURL,
            refresh: slots.refreshPullRequests)
        } else {
          PullRequestList(pullRequests: state.pullRequests, open: actions.openURL)
        }
      case .agents:
        if let agents = slots.agents {
          agents
        } else {
          AgentsPanel(state: state, open: actions.openSession)
        }
      case .info:
        SessionInspectorView(state: state, actions: actions)
      }
    }
  }
}

#if os(macOS)
  /// The Mac inspector's tab bar: segmented like the system control, with a neutral selected
  /// segment. Each tab is a button VoiceOver reports as selected or not; none is selected while
  /// a file or diff tab is on screen.
  private struct InspectorTabBar: View {
    let tabs: [InspectorTab]
    let selection: InspectorTab?
    let showsTitles: Bool
    let label: (InspectorTab) -> String
    let select: (InspectorTab) -> Void

    var body: some View {
      HStack(spacing: Theme.Spacing.tiny) {
        ForEach(tabs) { item in
          let isSelected = item == selection
          Button {
            select(item)
          } label: {
            Group {
              if showsTitles {
                Text(item.shortTitle)
              } else {
                // The button carries the tab's label.
                Image(systemName: item.systemImage).accessibilityHidden(true)
              }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? ThemeColor.primary : ThemeColor.mutedText)
            .padding(.horizontal, Theme.Spacing.small)
            .frame(minHeight: Theme.Control.target - Theme.Spacing.extraSmall)
            .frame(maxWidth: .infinity)
            .background {
              if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.small - 2, style: .continuous)
                  .fill(ThemeColor.surface)
                  .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(label(item))
          .accessibilityLabel(label(item))
          .accessibilityIdentifier("inspector-tab-\(item.rawValue)")
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
      }
      .padding(Theme.Spacing.tiny)
      .background(
        ThemeColor.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
      )
      .fixedSize(horizontal: showsTitles, vertical: false)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Right panel tab")
      .accessibilityHint("Switches between files, changes, pull requests, agents and info")
    }
  }
#endif
