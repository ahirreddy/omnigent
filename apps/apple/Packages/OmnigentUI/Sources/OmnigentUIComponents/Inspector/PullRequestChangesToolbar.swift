import OmnigentWorkspaceUI
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The Changes controls: Changes or Commits, the start point, the file list, conversations,
/// the path filter, find, the viewed progress, the layout and Collapse All. The find bar takes
/// its own row while open.
struct PullRequestChangesToolbar: View {
  let state: PullRequestChangesState
  let actions: PullRequestChangesActions
  let showsSidebar: Bool
  let toggleSidebar: () -> Void
  let inlineFilterOpen: Bool
  let toggleInlineFilter: () -> Void
  @Binding var findFocused: Bool

  private var showsCommits: Bool {
    if case .commits = state.body { return true }
    return false
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        leading
        Spacer(minLength: 0)
        trailing
      }
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.extraSmall)
      if let find = state.find, find.isOpen {
        Divider()
        PullRequestFindBar(state: find, actions: actions, focused: $findFocused)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, Theme.Spacing.extraSmall)
      }
    }
    .buttonStyle(.borderless)
    .font(.callout)
    .background(.bar)
    .accessibilityIdentifier("pr-changes-toolbar")
  }

  @ViewBuilder private var leading: some View {
    if state.offersCommits, let show = actions.showCommits {
      Picker(
        "Show changes or commits",
        selection: Binding(get: { state.showsCommitList }, set: { show($0) })
      ) {
        Text("Changes").tag(false)
        Text("Commits").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityIdentifier("pr-changes-mode")
    }
    if let since = state.changesSince {
      PullRequestChangesSincePicker(state: since, actions: actions)
    }
    if state.showsFileControls {
      iconButton(
        showsSidebar ? "Hide file list" : "Show file list",
        symbol: showsSidebar ? "sidebar.leading" : "sidebar.squares.leading",
        action: toggleSidebar)
    }
    if state.canNavigateThreads, let navigate = actions.navigateThread {
      iconButton("Previous unresolved conversation", symbol: "chevron.up") { navigate(false) }
      iconButton("Next unresolved conversation", symbol: "chevron.down") { navigate(true) }
    }
    if state.showsFileControls, !showsSidebar, state.offersFilter, !showsCommits {
      iconButton(
        inlineFilterOpen ? "Hide file filter" : "Show file filter",
        symbol: "line.3.horizontal.decrease", action: toggleInlineFilter)
    }
    if let find = state.find, !find.isOpen, let setOpen = actions.setFindOpen {
      iconButton("Find in changes", symbol: "magnifyingglass") {
        setOpen(true)
        findFocused = true
      }
      .accessibilityIdentifier("pr-find-open")
    }
  }

  @ViewBuilder private var trailing: some View {
    if let progress = state.progress {
      PullRequestViewedProgressView(progress: progress, setHide: actions.setHideViewed)
    }
    if state.isLoadingThreads {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Text("Loading review threads").font(.caption).foregroundStyle(.secondary)
        ProgressView().controlSize(.mini)
      }
      .accessibilityElement(children: .combine)
    }
    if state.showsFileControls, !showsCommits {
      if let setLayout = actions.setLayout {
        let split = state.layout == .split
        iconButton(
          split ? "Switch to unified view" : "Switch to split view",
          symbol: split ? "rectangle.split.1x2" : "rectangle.split.2x1"
        ) { setLayout(split ? .unified : .split) }
        .accessibilityIdentifier("pr-diff-layout")
      }
      if let toggleAll = actions.toggleAll {
        iconButton(
          state.allCollapsed ? "Expand all diffs" : "Collapse all diffs",
          symbol: state.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
          action: toggleAll)
      }
    }
  }

  private func iconButton(_ label: String, symbol: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).accessibilityLabel(label)
    }
    .help(label)
  }
}

/// The viewed count, a thin bar on wide layouts, and Hide viewed.
struct PullRequestViewedProgressView: View {
  let progress: PullRequestViewedProgress
  let setHide: (@MainActor (Bool) -> Void)?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.small) {
        Text(progress.label).foregroundStyle(.secondary).fixedSize()
        ProgressView(
          value: Double(progress.viewed), total: Double(max(progress.total, 1))
        )
        .frame(width: 48)
        .accessibilityLabel("Files viewed")
        hideToggle
      }
      HStack(spacing: Theme.Spacing.small) {
        Text(progress.label).foregroundStyle(.secondary).fixedSize()
        hideToggle
      }
    }
    .font(.caption)
    .accessibilityIdentifier("pr-viewed-progress")
  }

  @ViewBuilder private var hideToggle: some View {
    if let setHide {
      PullRequestCheckbox(title: "Hide viewed", isOn: progress.hideViewed) {
        setHide(!progress.hideViewed)
      }
      .fixedSize()
    }
  }
}

/// A checkbox on the Mac; iOS has none, so a button that stays highlighted while on.
struct PullRequestCheckbox: View {
  let title: String
  let isOn: Bool
  var accessibilityLabel: String?
  let toggle: () -> Void

  var body: some View {
    Toggle(isOn: Binding(get: { isOn }, set: { if $0 != isOn { toggle() } })) {
      Text(title)
    }
    #if os(macOS)
      .toggleStyle(.checkbox)
    #else
      .toggleStyle(.button)
    #endif
    .accessibilityLabel(accessibilityLabel ?? title)
  }
}

/// The find bar: the query, "k of N", matches in hidden files, match case, regular
/// expressions, previous and next, and close. Return steps forward, Shift-Return back, and
/// Escape closes.
struct PullRequestFindBar: View {
  let state: PullRequestFindState
  let actions: PullRequestChangesActions
  @Binding var focused: Bool

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      SearchField(
        "Find in changes\u{2026}",
        text: Binding(get: { state.query }, set: { actions.setFindQuery?($0) }),
        identifier: "pr-find-field",
        isFocused: $focused,
        submit: { actions.stepFind?(!Self.shiftHeld) },
        escape: {
          actions.setFindOpen?(false)
          return true
        }
      )
      .controlSize(.small)
      .frame(minWidth: 120)
      .accessibilityLabel("Find in changes")
      Text(state.status)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
        .accessibilityIdentifier("pr-find-status")
      if let hidden = state.hidden {
        Text(hidden).font(.caption).foregroundStyle(.secondary).fixedSize()
        if let show = actions.showHidden {
          Button("Show", action: show).font(.caption)
        }
      }
      option("Aa", label: "Match case", isOn: state.matchCase, toggle: actions.toggleMatchCase)
      option(".*", label: "Regular expression", isOn: state.regex, toggle: actions.toggleRegex)
      // Previous and next as one control, as the system's find bars pair them.
      ControlGroup {
        Button {
          actions.stepFind?(false)
        } label: {
          Image(systemName: "chevron.up").accessibilityLabel("Previous match")
        }
        .help("Previous match")
        Button {
          actions.stepFind?(true)
        } label: {
          Image(systemName: "chevron.down").accessibilityLabel("Next match")
        }
        .help("Next match")
      }
      .fixedSize()
      .disabled(state.total == 0)
      Button {
        actions.setFindOpen?(false)
      } label: {
        Image(systemName: "xmark").accessibilityLabel("Close find")
      }
      .help("Close find")
    }
    .accessibilityIdentifier("pr-find-bar")
  }

  /// Shift-Return steps back, as the web's find bar.
  private static var shiftHeld: Bool {
    #if os(macOS)
      NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
    #else
      false
    #endif
  }

  /// A find option as a toggle button, as the workspace search draws its own.
  private func option(
    _ title: String, label: String, isOn: Bool, toggle: (@MainActor () -> Void)?
  ) -> some View {
    Toggle(isOn: Binding(get: { isOn }, set: { if $0 != isOn { toggle?() } })) {
      Text(title).font(.caption.monospaced().weight(.semibold))
    }
    .toggleStyle(.button)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(toggle == nil)
    .help(label)
    .accessibilityLabel(label)
  }
}
