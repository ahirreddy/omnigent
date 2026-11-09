import Observation
import OmnigentUIComponents
import SwiftUI

/// A conversation's Chat/Terminal choice, for a key-path binding (`$route.mode`). With tabs,
/// the window keeps the choice, so it outlasts the chat's view.
///
/// A closure binding compares unequal on every update, so each navigation-bar update re-rendered
/// the conversation, which re-vended its bar items: a loop that held iPhone's main thread for
/// half a minute when a long session opened.
@Observable
final class ConversationModeRoute {
  private var stored: SessionViewMode = .chat
  /// The window's memory of the choice; `nil` without tabs.
  @ObservationIgnored var remembered: SessionViewChoice?

  /// The mode the screen shows.
  var mode: SessionViewMode {
    get { remembered.map { $0.mode ?? .chat } ?? stored }
    set {
      if let remembered {
        if remembered.mode != newValue { remembered.mode = newValue }
      } else if stored != newValue {
        stored = newValue
      }
    }
  }

  /// The screen's binding.
  /// - Parameters:
  ///   - remembered: The window's memory of the choice; `nil` without tabs.
  ///   - source: This object's `@State` binding, whose `mode` projection compares equal.
  /// - Returns: The binding.
  func mode(
    _ remembered: SessionViewChoice?, _ source: Binding<ConversationModeRoute>
  ) -> Binding<SessionViewMode> {
    self.remembered = remembered
    return source.mode
  }
}

/// Whether a conversation's right panel shows, for a key-path binding (`$route.isShown`) that
/// compares equal across updates, so the screen re-renders only when the panel changes.
@Observable
final class ConversationPanelRoute {
  /// The chat's own choice; `nil` until it shows or hides the panel.
  var choice: WorkspacePanelDefault?
  /// Whether the panel shows before the chat chooses.
  private(set) var showsByDefault = false

  /// Whether the panel shows; setting it records the chat's choice.
  var isShown: Bool {
    get { choice.map { $0 == .open } ?? showsByDefault }
    set {
      let chosen: WorkspacePanelDefault = newValue ? .open : .collapsed
      if choice != chosen { choice = chosen }
    }
  }

  /// The screen's binding, after updating what shows before the chat chooses (only a change is
  /// written, so the first render already has the right default).
  /// - Parameters:
  ///   - preference: The stored default (Settings).
  ///   - isSheet: The panel is a sheet (compact width), where it starts closed.
  ///   - source: This object's `@State` binding, whose `isShown` projection compares equal.
  /// - Returns: The binding.
  func isShown(
    default preference: WorkspacePanelDefault, isSheet: Bool,
    _ source: Binding<ConversationPanelRoute>
  ) -> Binding<Bool> {
    let shows = preference.showsPanel(isSheet: isSheet)
    if showsByDefault != shows { showsByDefault = shows }
    return source.isShown
  }
}
