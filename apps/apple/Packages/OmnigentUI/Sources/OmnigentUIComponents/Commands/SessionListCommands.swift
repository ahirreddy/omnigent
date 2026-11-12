import SwiftUI

/// The session list's display options as the menu bar shows and sets them. The sidebar
/// publishes it with `focusedSceneValue`.
struct SessionListCommandActions {
  /// What the menu shows: a new value is published only when this changes.
  nonisolated struct MenuSignature: Hashable {
    let options: SessionDisplayOptions
    let showsShared: Bool
  }

  /// The options in effect.
  var options: SessionDisplayOptions
  /// Whether the server shares sessions, which offers the Shared scope.
  var showsShared: Bool
  /// Writes new options.
  var set: @MainActor (SessionDisplayOptions) -> Void
}

extension SessionListCommandActions: FocusedActions {
  var menuSignature: MenuSignature { MenuSignature(options: options, showsShared: showsShared) }

  func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self {
    Self(options: options, showsShared: showsShared) { latest()?.set($0) }
  }
}

extension FocusedValues {
  /// The key window's session list display options.
  @Entry var sessionListCommands: SessionListCommandActions?
}

extension View {
  /// Publishes the session list's display options to the menu bar; none without `set`.
  func sessionListCommands(
    display: SessionDisplayOptions, showsShared: Bool,
    set: (@MainActor (SessionDisplayOptions) -> Void)?
  ) -> some View {
    modifier(
      SessionListCommandsPublisher(
        actions: set.map {
          SessionListCommandActions(options: display, showsShared: showsShared, set: $0)
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
      }
    } else {
      // A disabled menu still opens, empty; an item with nothing to run greys out.
      Button("Session List") {}.disabled(true)
    }
  }
}
