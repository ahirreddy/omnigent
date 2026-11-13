import SwiftUI

/// A group's sort choices as a picker: a submenu in a menu, with a checkmark on the current one.
struct GroupSortPicker: View {
  var title = "Sort sessions by"
  let sort: SessionGroupSort
  let set: @MainActor (SessionGroupSort) -> Void

  var body: some View {
    Picker(title, selection: Binding(get: { sort }, set: { if $0 != sort { set($0) } })) {
      ForEach(SessionGroupSort.allCases, id: \.self) { Text($0.title).tag($0) }
    }
  }
}

/// The Pinned header's sort menu: the choices themselves, since the header has nothing else.
struct PinnedSortMenu: View {
  let sort: SessionGroupSort
  let set: @MainActor (SessionGroupSort) -> Void

  var body: some View {
    Menu {
      GroupSortPicker(sort: sort, set: set).pickerStyle(.inline)
    } label: {
      Label("Sort pinned sessions", systemImage: "arrow.up.arrow.down")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Sort pinned sessions")
    .accessibilityIdentifier("sidebar-sort-pinned")
  }
}

/// A Move submenu (up, down, top, bottom) for one of `items`; a move that would leave it where
/// it is shows disabled.
struct MoveMenu<Item: Identifiable>: View {
  var title = "Move"
  /// The items in order, read when the menu opens.
  let items: () -> [Item]
  let id: Item.ID
  let save: @MainActor ([Item]) -> Void

  var body: some View {
    let items = items()
    Menu(title, systemImage: "arrow.up.arrow.down") {
      ForEach(ProjectMove.allCases) { move in
        let moved = items.moved(id, move)
        Button(move.title) { save(moved) }
          .disabled(moved.isEmpty)
      }
    }
  }
}

/// A session row's place among its group's rows (Pinned, or a project), for its Reorder menu.
struct SessionRowMove {
  /// The group's rows top to bottom.
  let rows: () -> [SessionSummary]
  /// Saves the rows in a new order.
  let save: @MainActor ([SessionSummary]) -> Void
}

/// One group's sort as the menu bar offers it.
nonisolated struct GroupSortChoice: Hashable, Identifiable {
  let group: SessionGroup
  /// The project's name; Pinned needs none.
  let title: String
  let sort: SessionGroupSort

  var id: SessionGroup { group }

  /// The groups `state` shows: Pinned while something is pinned, then each project.
  static func choices(_ state: SidebarViewState) -> [Self] {
    let pinned = Self(group: .pinned, title: "Pinned", sort: state.sort(of: .pinned))
    return (state.pinnedCount > 0 ? [pinned] : [])
      + state.projects.map { project in
        let group = SessionGroup.project(project.id)
        return Self(group: group, title: project.name, sort: state.sort(of: group))
      }
  }
}

/// The menu bar's sort of each group: Pinned's choices, and a submenu per project.
struct GroupSortMenuItems: View {
  let groups: [GroupSortChoice]
  let set: @MainActor (SessionGroup, SessionGroupSort) -> Void

  var body: some View {
    let projects = groups.filter { $0.group != .pinned }
    if !groups.isEmpty { Divider() }
    if let pinned = groups.first(where: { $0.group == .pinned }) {
      GroupSortPicker(title: "Sort Pinned Sessions By", sort: pinned.sort) { set(.pinned, $0) }
    }
    if !projects.isEmpty {
      Menu("Sort Project Sessions By") {
        ForEach(projects) { choice in
          GroupSortPicker(title: choice.title, sort: choice.sort) { set(choice.group, $0) }
        }
      }
    }
  }
}
