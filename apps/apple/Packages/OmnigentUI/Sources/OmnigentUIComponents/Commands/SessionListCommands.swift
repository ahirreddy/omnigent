import SwiftUI

/// The session list's display options and each group's sort as the menu bar shows and sets
/// them. The sidebar publishes it with `focusedSceneValue`.
struct SessionListCommandActions {
  /// What the menu shows: a new value is published only when this changes.
  nonisolated struct MenuSignature: Hashable {
    let options: SessionDisplayOptions
    let showsShared: Bool
    let groups: [GroupSortChoice]
  }

  /// The options in effect.
  var options: SessionDisplayOptions
  /// Whether the server shares sessions, which offers the Shared scope.
  var showsShared: Bool
  /// Pinned and each project with its sort; empty where the sidebar cannot sort them.
  var groups: [GroupSortChoice] = []
  /// Writes new options.
  var set: @MainActor (SessionDisplayOptions) -> Void
  /// Chooses a group's sort; `nil` where the sidebar cannot sort them.
  var setGroupSort: (@MainActor (SessionGroup, SessionGroupSort) -> Void)?
}

extension SessionListCommandActions: FocusedActions {
  var menuSignature: MenuSignature {
    MenuSignature(options: options, showsShared: showsShared, groups: groups)
  }

  func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self {
    var copy = Self(
      options: options, showsShared: showsShared, groups: groups, set: { latest()?.set($0) })
    if setGroupSort != nil { copy.setGroupSort = { latest()?.setGroupSort?($0, $1) } }
    return copy
  }
}

extension FocusedValues {
  /// The key window's session list display options.
  @Entry var sessionListCommands: SessionListCommandActions?
}

extension View {
  /// Publishes the sidebar's display options and group sorts to the menu bar; none where the
  /// sidebar cannot change its display.
  func sessionListCommands(_ state: SidebarViewState, actions: SidebarActions) -> some View {
    modifier(
      SessionListCommandsPublisher(
        actions: actions.setDisplay.map { setDisplay in
          SessionListCommandActions(
            options: state.display, showsShared: state.showsSharedScope,
            groups: actions.setGroupSort == nil ? [] : GroupSortChoice.choices(state),
            set: setDisplay, setGroupSort: actions.setGroupSort)
        }))
  }
}

private struct SessionListCommandsPublisher: ViewModifier {
  let actions: SessionListCommandActions?
  @State private var relay = FocusedActionsRelay<SessionListCommandActions>()

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.sessionListCommands, relay.publish(actions))
  }
}

/// View: the sidebar's display menu in the menu bar, where the keyboard and assistive clients
/// reach it. A list's section header, which holds the sidebar's, is one accessibility element.
struct SessionListMenuItems: View {
  let display: SessionListCommandActions?

  var body: some View {
    if let display {
      Menu("Session List") {
        DisplayMenuItems(
          options: display.options, showsShared: display.showsShared, set: display.set)
        if let setGroupSort = display.setGroupSort {
          GroupSortMenuItems(groups: display.groups, set: setGroupSort)
        }
      }
    } else {
      // A disabled menu still opens, empty; an item with nothing to run greys out.
      Button("Session List") {}.disabled(true)
    }
  }
}
