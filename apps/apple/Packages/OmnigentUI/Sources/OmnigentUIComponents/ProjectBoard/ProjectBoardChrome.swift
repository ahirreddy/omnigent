import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The board's header: the project's icon and name with its settings and menu, then the filter
/// and New session.
struct ProjectBoardHeader: View {
  let state: ProjectBoardViewState
  let actions: ProjectBoardActions
  let projectActions: SidebarActions
  let rename: () -> Void
  let confirmDelete: () -> Void

  var body: some View {
    HStack(spacing: Theme.Spacing.medium) {
      HStack(spacing: Theme.Spacing.small) {
        icon
        Text(state.project.name)
          .font(Theme.Typography.title)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        if let settings = projectActions.openProjectSettings {
          Button("Project settings", systemImage: "slider.horizontal.3") {
            settings(state.project)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Project settings")
          .accessibilityIdentifier("project-board-settings")
        }
        ProjectBoardProjectMenu(
          project: state.project, projectActions: projectActions, rename: rename,
          confirmDelete: confirmDelete, includesSettings: false)
      }
      .layoutPriority(1)
      Spacer(minLength: Theme.Spacing.medium)
      if let setFilter = actions.setFilter {
        SearchField(
          "Filter sessions", text: Binding(get: { state.filter }, set: setFilter),
          identifier: "project-board-filter"
        )
        .frame(maxWidth: 240)
      }
      if let toggle = actions.toggleComposer {
        Button(action: toggle) {
          Label("New Session", systemImage: "plus.bubble")
        }
        .buttonStyle(.borderedProminent)
        .help(state.isComposerShown ? "Hide the composer" : "Start a session in this project")
        .accessibilityValue(state.isComposerShown ? "Shown" : "Hidden")
        .accessibilityIdentifier("project-board-new-session")
      }
    }
    .padding(.horizontal, Theme.Spacing.large)
    .padding(.top, Theme.Spacing.medium)
    .padding(.bottom, Theme.Spacing.medium)
  }

  /// The project's emoji, else a folder in the window's accent.
  @ViewBuilder private var icon: some View {
    if let emoji = state.project.icon {
      Text(emoji).font(.title2).accessibilityHidden(true)
    } else {
      Image(systemName: "folder.fill")
        .font(.title2)
        .foregroundStyle(ThemeColor.controlTint)
        .accessibilityHidden(true)
    }
  }
}

/// The project's "…" menu: Rename and Delete, with Project settings where no button shows it.
struct ProjectBoardProjectMenu: View {
  let project: SessionProject
  let projectActions: SidebarActions
  let rename: () -> Void
  let confirmDelete: () -> Void
  let includesSettings: Bool

  var body: some View {
    Menu {
      if includesSettings, let settings = projectActions.openProjectSettings {
        Button("Project Settings\u{2026}", systemImage: "slider.horizontal.3") {
          settings(project)
        }
      }
      if projectActions.renameProject != nil {
        Button("Rename Project\u{2026}", systemImage: "pencil", action: rename)
      }
      if projectActions.deleteProject != nil {
        Divider()
        Button(
          "Delete Project\u{2026}", systemImage: "trash", role: .destructive, action: confirmDelete)
      }
    } label: {
      Label("Project actions for \(project.name)", systemImage: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .labelStyle(.iconOnly)
    #if os(macOS)
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .fixedSize()
    #endif
    .help("Project actions")
    .accessibilityIdentifier("project-board-actions")
  }
}

/// A session open beside the lanes: its title with Open full session and Close over its chat.
/// Its leading edge drags to resize it; Escape closes it.
struct ProjectBoardQuickView<Content: View>: View {
  let title: String
  let open: () -> Void
  let close: () -> Void
  @ViewBuilder let content: () -> Content

  /// The web's key, for the width a resize leaves.
  @AppStorage("omnigent:project-session-panel-width") private var width = 460.0
  @State private var dragStart: Double?

  static var minWidth: Double { 360 }

  var body: some View {
    HStack(spacing: 0) {
      handle
      VStack(spacing: 0) {
        header
        Divider()
        content()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: width)
      .background(.background)
    }
    #if os(macOS)
      .onExitCommand(perform: close)
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Session quick view")
    .accessibilityIdentifier("project-board-quick-view")
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.small) {
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Open full session", systemImage: "arrow.up.left.and.arrow.down.right", action: open)
        .help("Open full session")
        .accessibilityIdentifier("project-board-quick-view-open")
      Button("Close", systemImage: "xmark", action: close)
        .help("Close")
        .accessibilityIdentifier("project-board-quick-view-close")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, Theme.Spacing.medium)
    .frame(height: 40)
  }

  /// The divider between the lanes and the panel; dragging it resizes the panel.
  private var handle: some View {
    Divider()
      .overlay {
        Color.clear
          .frame(width: 8)
          .contentShape(Rectangle())
          #if os(macOS)
            .onHover { inside in
              if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
          #endif
          .gesture(
            DragGesture(minimumDistance: 1)
              .onChanged { value in
                let start = dragStart ?? width
                dragStart = start
                width = max(Self.minWidth, start - value.translation.width)
              }
              .onEnded { _ in dragStart = nil }
          )
          .accessibilityHidden(true)
      }
  }
}
