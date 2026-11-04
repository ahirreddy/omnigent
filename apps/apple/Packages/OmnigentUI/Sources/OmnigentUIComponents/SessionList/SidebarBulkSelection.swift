import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The web's "Select sessions" mode: which rows are checked, and the anchor a Shift-click
/// extends from.
nonisolated struct SidebarBulkSelection: Hashable {
  /// Selection mode is on.
  var isActive = false
  /// The checked session ids.
  var ids: Set<String> = []
  /// The last row toggled without Shift.
  var anchor: String?

  /// Turns selection mode on with nothing checked.
  mutating func begin() {
    self = Self(isActive: true)
  }

  /// Leaves selection mode.
  mutating func end() {
    self = Self()
  }

  /// Unchecks everything, staying in selection mode.
  mutating func clear() {
    ids = []
    anchor = nil
  }

  /// Toggles `id`, or with `extending` checks every row from the anchor to `id` in `order` (the
  /// rows on screen), as the web's `computeShiftSelectRange`.
  mutating func toggle(_ id: String, extending: Bool, order: [String]) {
    if extending, let anchor, let from = order.firstIndex(of: anchor),
      let to = order.firstIndex(of: id)
    {
      ids.formUnion(order[min(from, to)...max(from, to)])
      return
    }
    if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    anchor = id
  }

  /// Whether Shift is held, for a click that extends the selection.
  @MainActor static var isExtending: Bool {
    #if os(macOS)
      NSEvent.modifierFlags.contains(.shift)
    #else
      false
    #endif
  }
}

/// The bulk action bar under the sidebar while selecting: Mark read or unread, Archive,
/// Unarchive, Move to project and Delete, as the web's `BulkActionBar`. Ownership gates
/// Archive, Move and Delete; read state is per viewer, so it applies to every row.
struct BulkActionBar: View {
  let selected: [SessionSummary]
  let state: SidebarViewState
  let actions: SidebarActions
  let exit: () -> Void
  let clear: () -> Void
  let confirmDelete: ([SessionSummary]) -> Void

  private var owned: [SessionSummary] {
    selected.filter { state.rowInfo[$0.id]?.isShared != true }
  }
  private var unread: [SessionSummary] {
    selected.filter { state.list.unreadIds.contains($0.id) }
  }
  private var archived: [SessionSummary] { owned.filter(\.isArchived) }
  private var active: [SessionSummary] { owned.filter { !$0.isArchived } }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      Button("Exit selection", systemImage: "xmark", action: exit)
        .help("Exit selection")
        .accessibilityIdentifier("bulk-exit")
      Text("\(selected.count) selected")
        .font(.callout.weight(.medium))
        .lineLimit(1)
        .fixedSize()
      Spacer(minLength: 4)
      readButton
      if let setArchived = actions.setArchivedMany {
        if !active.isEmpty, archived.isEmpty {
          Button("Archive", systemImage: "archivebox") {
            setArchived(active, true)
            clear()
          }
          .help("Archive")
          .accessibilityIdentifier("bulk-archive")
        }
        if !archived.isEmpty, active.isEmpty {
          Button("Unarchive", systemImage: "tray.and.arrow.up") {
            setArchived(archived, false)
            clear()
          }
          .help("Unarchive")
          .accessibilityIdentifier("bulk-unarchive")
        }
      }
      moveMenu
      if actions.sessions.delete != nil, !owned.isEmpty {
        let label = owned.count == selected.count ? "Delete" : "Delete \(owned.count)"
        Button(label, systemImage: "trash") { confirmDelete(owned) }
          .help(label)
          .accessibilityIdentifier("bulk-delete")
      }
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    .padding(Theme.Spacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bulk-action-bar")
  }

  @ViewBuilder private var readButton: some View {
    if let setUnread = actions.sessions.setUnread, !selected.isEmpty {
      if !unread.isEmpty {
        Button("Mark as read", systemImage: "envelope.open") {
          for session in unread { setUnread(session, false) }
          exit()
        }
        .help("Mark as read")
        .accessibilityIdentifier("bulk-mark-read")
      } else {
        Button("Mark as unread", systemImage: "envelope.badge") {
          for session in selected { setUnread(session, true) }
          exit()
        }
        .help("Mark as unread")
        .accessibilityIdentifier("bulk-mark-unread")
      }
    }
  }

  @ViewBuilder private var moveMenu: some View {
    if let move = actions.sessions.moveToProject, !owned.isEmpty, !state.projects.isEmpty {
      Menu {
        ForEach(state.projects) { project in
          Button(project.name) {
            for session in owned { move(session, project) }
            exit()
          }
        }
        Divider()
        Button("Remove from project") {
          for session in owned { move(session, nil) }
          exit()
        }
      } label: {
        Label("Move to project", systemImage: "folder")
      }
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Move to project")
      .accessibilityIdentifier("bulk-move-to-project")
    }
  }
}
