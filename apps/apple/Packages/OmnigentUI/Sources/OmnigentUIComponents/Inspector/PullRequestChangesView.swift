import OmnigentWorkspaceUI
public import SwiftUI

/// The pull request's Changes tab, as the web's `PullRequestChangesTab` lays it out: notices, a
/// toolbar (Changes or Commits, changes since a commit, the file list, conversations, find,
/// viewed progress, layout and collapse), then a resizable file tree beside every file's diff
/// in one scroll, or the commit list.
public struct PullRequestChangesView: View {
  private let state: PullRequestChangesState
  private let actions: PullRequestChangesActions

  @State private var sidebarChoice = SidebarChoice.automatic
  @State private var sidebarWidth: CGFloat = 192
  @State private var inlineFilterOpen = false
  @State private var findFocused = false
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// Creates the tab.
  /// - Parameters:
  ///   - state: What it shows.
  ///   - actions: What its controls do.
  public init(state: PullRequestChangesState, actions: PullRequestChangesActions) {
    self.state = state
    self.actions = actions
  }

  private var compact: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  /// Whether the reader showed or hid the file list.
  private enum SidebarChoice { case automatic, shown, hidden }

  /// The file list starts hidden on a phone, as on the web's narrow layout.
  private var showsSidebar: Bool {
    switch sidebarChoice {
    case .automatic: !compact
    case .shown: true
    case .hidden: false
    }
  }

  private var showsCommits: Bool {
    if case .commits = state.body { return true }
    return false
  }

  /// The toolbar shows when there is something to control.
  private var showsToolbar: Bool {
    state.showsFileControls || state.offersCommits || state.isLoadingThreads
      || state.canNavigateThreads
  }

  /// The view.
  public var body: some View {
    VStack(spacing: 0) {
      notices
      if showsToolbar {
        PullRequestChangesToolbar(
          state: state, actions: actions, showsSidebar: showsSidebar,
          toggleSidebar: { sidebarChoice = showsSidebar ? .hidden : .shown },
          inlineFilterOpen: inlineFilterOpen,
          toggleInlineFilter: toggleInlineFilter, findFocused: $findFocused)
        Divider()
      }
      if !showsSidebar, inlineFilterOpen, state.offersFilter, !showsCommits {
        PullRequestPathFilterField(value: state.pathFilter, set: actions.setPathFilter)
          .padding(Theme.Spacing.small)
        Divider()
      }
      if let bar = state.commitBar {
        PullRequestCommitBar(state: bar, actions: actions)
        Divider()
      }
      HStack(spacing: 0) {
        if showsSidebar, !showsCommits {
          PullRequestChangesSidebar(state: state, actions: actions, width: $sidebarWidth)
          Divider()
        }
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if state.localCommentsFailed {
        HStack {
          Text("Local comments could not be loaded.").font(.callout)
          if let retry = actions.retryLocalComments {
            Button("Retry", action: retry).buttonStyle(.borderless)
          }
          Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.small)
      }
    }
    .background { findShortcut }
    .onChange(of: showsSidebar) { _, shown in
      // A filter set in the sidebar stays in sight once the sidebar hides.
      inlineFilterOpen = !shown && !state.pathFilter.isEmpty
    }
    .accessibilityIdentifier("pr-changes")
  }

  /// Command-F opens find, or with it open focuses its query, as the web's Changes tab.
  @ViewBuilder private var findShortcut: some View {
    if state.find != nil, let setOpen = actions.setFindOpen {
      Button("Find in Changes") {
        setOpen(true)
        findFocused = true
      }
      .keyboardShortcut("f", modifiers: .command)
      .opacity(0)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
  }

  /// Hiding the inline filter also clears it, so an active filter is never out of sight.
  private func toggleInlineFilter() {
    if inlineFilterOpen { actions.setPathFilter?("") }
    inlineFilterOpen.toggle()
  }

  @ViewBuilder private var notices: some View {
    if state.reviewNotice != nil || state.hasMoreThreads {
      HStack(spacing: Theme.Spacing.small) {
        if state.hasMoreThreads, let load = actions.loadMoreThreads {
          Button("Load more conversations", action: load).buttonStyle(.borderless)
        }
        if let notice = state.reviewNotice {
          Text(notice).foregroundStyle(Theme.failure)
        }
        Spacer(minLength: 0)
      }
      .font(.callout)
      .padding(Theme.Spacing.small)
      Divider()
    }
    if let notice = state.listingNotice {
      noticeRow(notice)
    }
    if let note = state.coverageNote {
      noticeRow(note, font: .caption)
    }
    if state.showsResetNotice {
      HStack {
        Text("New commits since you last viewed \u{2014} changed files lost their viewed marks.")
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if let dismiss = actions.dismissResetNotice {
          Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
      }
      .font(.callout)
      .padding(Theme.Spacing.small)
      .accessibilityIdentifier("pr-viewed-reset")
      Divider()
    }
  }

  private func noticeRow(_ text: String, font: Font = .callout) -> some View {
    VStack(spacing: 0) {
      Text(text)
        .font(font)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.small)
      Divider()
    }
  }

  @ViewBuilder private var content: some View {
    switch state.body {
    case .commits(let commits):
      PullRequestCommitsList(state: commits, actions: actions)
    case .message(let text, let isLoading, let action):
      VStack(spacing: Theme.Spacing.small) {
        if isLoading { ProgressView() }
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        if let action {
          Button(action.title, action: action.run)
        }
      }
      .padding(Theme.Spacing.large)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .diff(let diff):
      StackedDiffList(content: diff, actions: actions.diff)
    }
  }
}

/// The path filter: narrows the changed files by path; Escape clears it.
struct PullRequestPathFilterField: View {
  let value: String
  let set: (@MainActor (String) -> Void)?

  var body: some View {
    SearchField(
      "Filter files\u{2026}", text: Binding(get: { value }, set: { set?($0) }),
      identifier: "pr-path-filter",
      escape: {
        guard !value.isEmpty else { return false }
        set?("")
        return true
      }
    )
    .controlSize(.small)
    .accessibilityLabel("Filter changed files")
  }
}
